import Darwin
import Foundation
import KazeDomain
import KazeIPC

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let controller: SafetyController

    init(controller: SafetyController) {
        self.controller = controller
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let consoleUID = currentConsoleUserID(),
              consoleUID != 0,
              connection.effectiveUserIdentifier == consoleUID else {
            return false
        }

        let sessionID = UUID()
        let session = HelperSession(controller: controller, sessionID: sessionID)
        connection.exportedInterface = NSXPCInterface(with: KazeHelperXPC.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak controller] in
            controller?.connectionClosed(sessionID)
        }
        connection.interruptionHandler = { }
        connection.activate()
        return true
    }

    private func currentConsoleUserID() -> uid_t? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: "/dev/console"),
              let owner = attributes[.ownerAccountID] as? NSNumber else { return nil }
        return uid_t(owner.uint32Value)
    }
}

private final class HelperSession: NSObject, KazeHelperXPC {
    private let controller: SafetyController
    private let sessionID: UUID
    private let replayWindow = RequestReplayWindow()

    init(controller: SafetyController, sessionID: UUID) {
        self.controller = controller
        self.sessionID = sessionID
    }

    func perform(_ requestData: NSData, withReply reply: @escaping (NSData) -> Void) {
        let data = requestData as Data
        let response: HelperResponse
        var restartAfterReply = false
        do {
            let request = try XPCCodec.decodeRequest(data)
            guard replayWindow.accept(request.requestID) else { throw XPCCodecError.duplicateRequest }
            let result: HelperResult
            switch request.operation {
            case .status:
                result = HelperResult(status: controller.status())
            case .telemetry(let windowSeconds, let maximumPoints):
                let telemetry = try controller.telemetry(
                    windowSeconds: windowSeconds,
                    maximumPoints: maximumPoints
                )
                result = HelperResult(status: controller.status(), telemetry: telemetry)
            case .acquire(let intent, let leaseSeconds):
                result = HelperResult(
                    status: try controller.acquire(
                        intent: intent,
                        ownerSessionID: sessionID,
                        leaseSeconds: leaseSeconds
                    )
                )
            case .renew(let leaseID):
                result = HelperResult(
                    status: try controller.renew(leaseID: leaseID, ownerSessionID: sessionID)
                )
            case .resetAutomatic:
                result = HelperResult(status: try controller.resetAutomatic())
            case .restartForUpdate:
                result = HelperResult(status: try controller.resetAutomatic())
                restartAfterReply = true
            }
            response = HelperResponse(requestID: request.requestID, result: result)
        } catch {
            let requestID = (try? XPCCodec.decode(HelperRequest.self, from: data).requestID) ?? UUID()
            response = HelperResponse(
                requestID: requestID,
                error: HelperRPCError(code: errorCode(error), message: sanitizedMessage(error))
            )
        }

        if let encoded = try? XPCCodec.encode(response) {
            reply(encoded as NSData)
        } else {
            // This fixed response is intentionally tiny and contains no interpolated
            // internal state, so encoding failure cannot turn into information leak.
            let fallback = "{\"protocolVersion\":\(KazeVersion.protocolVersion)}".data(using: .utf8) ?? Data()
            reply(fallback as NSData)
        }

        if restartAfterReply {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [controller] in
                controller.shutdown()
                Darwin.exit(0)
            }
        }
    }

    private func errorCode(_ error: Error) -> String {
        switch error {
        case is XPCCodecError: return "invalid-request"
        case DomainError.invalidRPM: return "invalid-rpm"
        case DomainError.invalidLeaseDuration: return "invalid-lease"
        case DomainError.invalidTelemetryWindow, DomainError.invalidTelemetryPointLimit:
            return "invalid-telemetry-query"
        case DomainError.controlOwnedByAnotherSession: return "control-busy"
        case DomainError.leaseNotOwned: return "lease-not-owned"
        case DomainError.leaseExpired: return "lease-expired"
        case is DomainError: return "control-failed"
        default: return "internal-error"
        }
    }

    private func sanitizedMessage(_ error: Error) -> String {
        switch error {
        case let error as XPCCodecError: return error.description
        case let error as DomainError: return error.description
        default: return "the helper could not complete the request"
        }
    }
}
