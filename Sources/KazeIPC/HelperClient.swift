import Foundation
import KazeDomain

public enum HelperClientError: Error, Sendable, CustomStringConvertible {
    case unavailable(String)
    case invalidProxy
    case remote(HelperRPCError)
    case missingResult
    case missingTelemetry
    case timedOut(seconds: Double)

    public var description: String {
        switch self {
        case .unavailable(let message): return "helper unavailable: \(message)"
        case .invalidProxy: return "helper returned an invalid XPC proxy"
        case .remote(let error): return error.description
        case .missingResult: return "helper response had neither a result nor an error"
        case .missingTelemetry: return "helper response did not contain telemetry"
        case .timedOut(let seconds): return "helper request timed out after \(seconds) seconds"
        }
    }

    public var isConnectionFailure: Bool {
        switch self {
        case .unavailable, .invalidProxy, .timedOut:
            true
        case .remote, .missingResult, .missingTelemetry:
            false
        }
    }
}

public final class HelperClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let developmentMode: Bool

    public init(developmentMode: Bool = DevelopmentMode.isEnabled) {
        self.developmentMode = developmentMode
    }

    deinit {
        invalidate()
    }

    public func invalidate() {
        lock.lock()
        let current = connection
        connection = nil
        lock.unlock()
        current?.invalidate()
    }

    public func perform(
        _ operation: HelperOperation,
        timeoutSeconds: Double = 5
    ) async throws -> ControllerStatus {
        try await performResult(operation, timeoutSeconds: timeoutSeconds).status
    }

    public func fetchTelemetry(
        windowSeconds: Double,
        maximumPoints: Int = 180,
        timeoutSeconds: Double = 5
    ) async throws -> HelperTelemetrySnapshot {
        let result = try await performResult(
            .telemetry(windowSeconds: windowSeconds, maximumPoints: maximumPoints),
            timeoutSeconds: timeoutSeconds
        )
        guard let telemetry = result.telemetry else { throw HelperClientError.missingTelemetry }
        return HelperTelemetrySnapshot(status: result.status, samples: telemetry)
    }

    private func performResult(
        _ operation: HelperOperation,
        timeoutSeconds: Double
    ) async throws -> HelperResult {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw HelperClientError.timedOut(seconds: timeoutSeconds)
        }
        let request = HelperRequest(operation: operation)
        let payload = try XPCCodec.encode(request)
        let connection = try activeConnection()

        do {
            return try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate(continuation)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + timeoutSeconds
                ) {
                    gate.fail(HelperClientError.timedOut(seconds: timeoutSeconds))
                }
                let proxyObject = connection.remoteObjectProxyWithErrorHandler { error in
                    let connectionError = error as NSError
                    gate.fail(HelperClientError.unavailable(
                        "\(connectionError.localizedDescription) "
                            + "[\(connectionError.domain) \(connectionError.code)]"
                    ))
                }
                guard let proxy = proxyObject as? KazeHelperXPC else {
                    gate.fail(HelperClientError.invalidProxy)
                    return
                }
                proxy.perform(payload as NSData) { responseData in
                    do {
                        let response = try XPCCodec.decodeResponse(responseData as Data, for: request)
                        if let error = response.error { throw HelperClientError.remote(error) }
                        guard let result = response.result else { throw HelperClientError.missingResult }
                        gate.succeed(result)
                    } catch {
                        gate.fail(error)
                    }
                }
            }
        } catch {
            if (error as? HelperClientError)?.isConnectionFailure == true {
                discardAndInvalidateIfCurrent(connection)
            }
            throw error
        }
    }

    private func activeConnection() throws -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        let newConnection = NSXPCConnection(
            machServiceName: IPCConstants.machServiceName,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(with: KazeHelperXPC.self)
        newConnection.setCodeSigningRequirement(
            try CodeSigningPolicy.helperRequirement(developmentMode: developmentMode)
        )
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
            guard let newConnection else { return }
            self?.discardAndInvalidateIfCurrent(newConnection)
        }
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let newConnection else { return }
            self?.discardIfCurrent(newConnection)
        }
        newConnection.activate()
        connection = newConnection
        return newConnection
    }

    private func discardIfCurrent(_ invalidated: NSXPCConnection) {
        lock.lock()
        if connection === invalidated { connection = nil }
        lock.unlock()
    }

    private func discardAndInvalidateIfCurrent(_ failed: NSXPCConnection) {
        lock.lock()
        let wasCurrent = connection === failed
        if wasCurrent { connection = nil }
        lock.unlock()
        if wasCurrent { failed.invalidate() }
    }
}

public struct HelperTelemetrySnapshot: Sendable, Equatable {
    public let status: ControllerStatus
    public let samples: [TelemetrySample]

    public init(status: ControllerStatus, samples: [TelemetrySample]) {
        self.status = status
        self.samples = samples
    }
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
