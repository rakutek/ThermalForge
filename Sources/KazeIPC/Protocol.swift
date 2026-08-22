import Foundation
import KazeDomain

public enum IPCConstants {
    public static let machServiceName = "com.producerguy.kaze.helper"
    public static let launchDaemonPlistName = "com.producerguy.kaze.helper.plist"
    public static let appIdentifier = "com.producerguy.kaze"
    public static let cliIdentifier = "com.producerguy.kaze.cli"
    public static let helperIdentifier = "com.producerguy.kaze.helper"
}

@objc public protocol KazeHelperXPC {
    func perform(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
}

public struct HelperRequest: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let protocolVersion: Int
    public let operation: HelperOperation

    public init(requestID: UUID = UUID(), operation: HelperOperation) {
        self.requestID = requestID
        self.protocolVersion = KazeVersion.protocolVersion
        self.operation = operation
    }
}

public enum HelperOperation: Codable, Sendable, Equatable {
    case status
    case acquire(intent: ControlIntent, leaseSeconds: Double)
    case renew(leaseID: UUID)
    case resetAutomatic
}

public struct HelperResult: Codable, Sendable, Equatable {
    public let status: ControllerStatus

    public init(status: ControllerStatus) {
        self.status = status
    }
}

public struct HelperRPCError: Codable, Error, Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }
}

public struct HelperResponse: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let protocolVersion: Int
    public let result: HelperResult?
    public let error: HelperRPCError?

    public init(requestID: UUID, result: HelperResult) {
        self.requestID = requestID
        self.protocolVersion = KazeVersion.protocolVersion
        self.result = result
        self.error = nil
    }

    public init(requestID: UUID, error: HelperRPCError) {
        self.requestID = requestID
        self.protocolVersion = KazeVersion.protocolVersion
        self.result = nil
        self.error = error
    }
}

public enum XPCCodecError: Error, Sendable, Equatable, CustomStringConvertible {
    case payloadTooLarge(Int)
    case malformedPayload
    case protocolMismatch(received: Int)
    case responseMismatch
    case duplicateRequest

    public var description: String {
        switch self {
        case .payloadTooLarge(let size): return "XPC payload is too large: \(size) bytes"
        case .malformedPayload: return "malformed XPC payload"
        case .protocolMismatch(let received): return "unsupported protocol version: \(received)"
        case .responseMismatch: return "XPC response did not match its request"
        case .duplicateRequest: return "duplicate XPC request"
        }
    }
}

public final class RequestReplayWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers = Set<UUID>()
    private var insertionOrder: [UUID] = []
    private let capacity = 1_024

    public init() {}

    public func accept(_ identifier: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard identifiers.insert(identifier).inserted else { return false }
        insertionOrder.append(identifier)
        if insertionOrder.count > capacity {
            identifiers.remove(insertionOrder.removeFirst())
        }
        return true
    }
}

public enum XPCCodec {
    public static let maximumPayloadBytes = 64 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumPayloadBytes else { throw XPCCodecError.payloadTooLarge(data.count) }
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumPayloadBytes else { throw XPCCodecError.payloadTooLarge(data.count) }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw XPCCodecError.malformedPayload }
    }

    public static func decodeRequest(_ data: Data) throws -> HelperRequest {
        let request = try decode(HelperRequest.self, from: data)
        guard request.protocolVersion == KazeVersion.protocolVersion else {
            throw XPCCodecError.protocolMismatch(received: request.protocolVersion)
        }
        return request
    }

    public static func decodeResponse(_ data: Data, for request: HelperRequest) throws -> HelperResponse {
        let response = try decode(HelperResponse.self, from: data)
        guard response.protocolVersion == KazeVersion.protocolVersion else {
            throw XPCCodecError.protocolMismatch(received: response.protocolVersion)
        }
        guard response.requestID == request.requestID else { throw XPCCodecError.responseMismatch }
        return response
    }
}
