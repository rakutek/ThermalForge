import Foundation
import IOKit
import KazeDomain

enum SMCTransportError: Error, CustomStringConvertible {
    case serviceUnavailable
    case openFailed(kern_return_t)
    case invalidKey(String)
    case keyInfoFailed(String, kern_return_t)
    case invalidDataSize(String, UInt32)
    case readFailed(String, kern_return_t)
    case writeFailed(String, kern_return_t)
    case firmwareRejected(String, UInt8)

    var description: String {
        switch self {
        case .serviceUnavailable: return "AppleSMC service is unavailable"
        case .openFailed(let code): return "AppleSMC open failed: \(code)"
        case .invalidKey(let key): return "invalid four-byte SMC key: \(key)"
        case .keyInfoFailed(let key, let code): return "SMC key info failed for \(key): \(code)"
        case .invalidDataSize(let key, let size): return "invalid SMC size for \(key): \(size)"
        case .readFailed(let key, let code): return "SMC read failed for \(key): \(code)"
        case .writeFailed(let key, let code): return "SMC write failed for \(key): \(code)"
        case .firmwareRejected(let key, let result): return "SMC firmware rejected \(key): \(result)"
        }
    }
}

struct SMCValue: Sendable, Equatable {
    let type: String
    let bytes: [UInt8]
}

protocol SMCTransport: AnyObject {
    func read(_ key: String) throws -> SMCValue
    func write(_ key: String, bytes: [UInt8]) throws
}

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case readKeyInfo = 9
}

private let smcSelector: UInt32 = 2

private struct SMCParamStruct {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = zeroBytes
}

private typealias Bytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private let zeroBytes: Bytes = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
)

final class AppleSMCTransport: SMCTransport {
    private let connection: io_connect_t

    init() throws {
        var iterator: io_iterator_t = 0
        defer { IOObjectRelease(iterator) }
        let matchResult = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC"),
            &iterator
        )
        guard matchResult == kIOReturnSuccess else { throw SMCTransportError.serviceUnavailable }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { throw SMCTransportError.serviceUnavailable }
        defer { IOObjectRelease(service) }

        var opened: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &opened)
        guard result == kIOReturnSuccess else { throw SMCTransportError.openFailed(result) }
        connection = opened
    }

    deinit {
        IOServiceClose(connection)
    }

    func read(_ key: String) throws -> SMCValue {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = try fourCharacterCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        var result = call(&input, &output)
        guard result == kIOReturnSuccess else { throw SMCTransportError.keyInfoFailed(key, result) }

        let size = output.keyInfo.dataSize
        guard (1...32).contains(size) else { throw SMCTransportError.invalidDataSize(key, size) }
        let type = fourCharacterString(output.keyInfo.dataType)

        input.keyInfo.dataSize = size
        input.data8 = SMCCommand.readBytes.rawValue
        result = call(&input, &output)
        guard result == kIOReturnSuccess else { throw SMCTransportError.readFailed(key, result) }
        guard output.result == 0 else { throw SMCTransportError.firmwareRejected(key, output.result) }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(size))) }
        return SMCValue(type: type, bytes: bytes)
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = try fourCharacterCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        var result = call(&input, &output)
        guard result == kIOReturnSuccess else { throw SMCTransportError.keyInfoFailed(key, result) }

        let expectedSize = output.keyInfo.dataSize
        guard (1...32).contains(expectedSize), expectedSize == bytes.count else {
            throw SMCTransportError.invalidDataSize(key, expectedSize)
        }

        input.data8 = SMCCommand.writeBytes.rawValue
        input.keyInfo.dataSize = expectedSize
        input.bytes = tuple(from: bytes)
        result = call(&input, &output)
        guard result == kIOReturnSuccess else { throw SMCTransportError.writeFailed(key, result) }
        guard output.result == 0 else { throw SMCTransportError.firmwareRejected(key, output.result) }
    }

    private func call(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> kern_return_t {
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        return IOConnectCallStructMethod(
            connection,
            smcSelector,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
    }
}

func fourCharacterCode(_ key: String) throws -> UInt32 {
    let bytes = Array(key.utf8)
    guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
        throw SMCTransportError.invalidKey(key)
    }
    return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
}

private func fourCharacterString(_ code: UInt32) -> String {
    String(bytes: [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ], encoding: .ascii) ?? "????"
}

private func tuple(from input: [UInt8]) -> Bytes {
    let bytes = input + Array(repeating: 0, count: 32 - input.count)
    return (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23],
        bytes[24], bytes[25], bytes[26], bytes[27], bytes[28], bytes[29], bytes[30], bytes[31]
    )
}

func decodeSMCFloat(_ bytes: [UInt8]) throws -> Double {
    guard bytes.count == 4 else { throw SMCTransportError.invalidDataSize("flt", UInt32(bytes.count)) }
    var value: Float = 0
    withUnsafeMutableBytes(of: &value) { destination in
        destination.copyBytes(from: bytes)
    }
    let result = Double(value)
    guard result.isFinite else { throw DomainError.invalidTemperature(result) }
    return result
}

func encodeSMCFloat(_ value: Double) throws -> [UInt8] {
    guard value.isFinite, value >= 0, value <= 20_000 else {
        throw HardwareError.write("non-finite or out-of-range floating-point value")
    }
    var float = Float(value)
    return withUnsafeBytes(of: &float) { Array($0) }
}

func decodeIOFixedTemperature(_ bytes: [UInt8]) throws -> Double {
    guard bytes.count >= 4 else { throw SMCTransportError.invalidDataSize("ioft", UInt32(bytes.count)) }
    let raw = UInt32(bytes[0])
        | UInt32(bytes[1]) << 8
        | UInt32(bytes[2]) << 16
        | UInt32(bytes[3]) << 24
    return Double(raw >> 16) + Double(raw & 0xFFFF) / 65_536
}
