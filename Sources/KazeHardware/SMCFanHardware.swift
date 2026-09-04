import Foundation
import KazeDomain

public enum HardwareError: Error, Sendable, CustomStringConvertible {
    case read(String)
    case write(String)
    case invalidFanCount(Int)
    case invalidFanReading(Int)
    case noSupportedModeKey
    case verification(String)

    public var description: String {
        switch self {
        case .read(let detail): return "read failed: \(detail)"
        case .write(let detail): return "write failed: \(detail)"
        case .invalidFanCount(let count): return "invalid hardware fan count: \(count)"
        case .invalidFanReading(let index): return "invalid reading for fan \(index)"
        case .noSupportedModeKey: return "no supported fan mode key"
        case .verification(let detail): return "SMC read-back verification failed: \(detail)"
        }
    }
}

private struct SensorSpec {
    enum Encoding { case float, ioFixed }
    let key: String
    let family: SensorFamily
    let limit: Double
    let required: Bool
    let encoding: Encoding
}

public final class SMCFanHardware: ThermalHardware, @unchecked Sendable {
    public let inventory: HardwareInventory

    private let transport: SMCTransport
    private let lock = NSRecursiveLock()
    private let modeTemplate: String
    private let hasForceTest: Bool
    private let sensorSpecs: [SensorSpec]

    public convenience init() throws {
        try self.init(transport: AppleSMCTransport())
    }

    init(transport: SMCTransport) throws {
        self.transport = transport

        let countValue = try transport.read("FNum")
        guard let first = countValue.bytes.first else { throw HardwareError.invalidFanCount(0) }
        let fanCount = Int(first)
        guard (1...8).contains(fanCount) else { throw HardwareError.invalidFanCount(fanCount) }

        if (try? transport.read("F0md")) != nil {
            modeTemplate = "F%dmd"
        } else if (try? transport.read("F0Md")) != nil {
            modeTemplate = "F%dMd"
        } else {
            throw HardwareError.noSupportedModeKey
        }
        hasForceTest = (try? transport.read("Ftst")) != nil

        var limits: [FanLimits] = []
        for index in 0..<fanCount {
            let minimum = try Self.readRPM(transport, key: Self.fanKey("F%dMn", index))
            let maximum = try Self.readRPM(transport, key: Self.fanKey("F%dMx", index))
            limits.append(try FanLimits(index: index, minimumRPM: minimum, maximumRPM: maximum))
        }

        let discovered = Self.knownSensors.compactMap { spec -> (SensorSpec, SensorDescriptor)? in
            guard let value = try? Self.readTemperature(transport, spec: spec),
                  value.isFinite, (-20...150).contains(value),
                  let descriptor = try? SensorDescriptor(
                    key: spec.key,
                    family: spec.family,
                    safetyLimitCelsius: spec.limit,
                    required: spec.required
                  )
            else { return nil }
            return (spec, descriptor)
        }
        sensorSpecs = discovered.map(\.0)
        inventory = try HardwareInventory(fans: limits, sensors: discovered.map(\.1))
    }

    public func sample() throws -> HardwareSample {
        try lock.withLock { try sampleUnlocked() }
    }

    public func applyManual(targetRPMs: [Int]) throws -> HardwareSample {
        try lock.withLock {
            guard targetRPMs.count == inventory.fans.count else {
                throw HardwareError.verification("target count does not match fan count")
            }
            for (limits, target) in zip(inventory.fans, targetRPMs) {
                guard limits.contains(target) else { throw DomainError.invalidRPM(target) }
            }

            if hasForceTest {
                try retryWrite("Ftst", bytes: [1])

                // On Apple Silicon generations that expose Ftst, thermalmonitord
                // does not release the fan mode keys immediately. Ftst itself is
                // command-like on some models and may read back as zero after a
                // successful write, so the authoritative verification is that
                // every fan mode actually latches below.
                Thread.sleep(forTimeInterval: 0.05)
            }
            try enterManualMode()
            try applyTargets(targetRPMs)

            let verified = try sampleUnlocked()
            try verifyManual(verified, targets: targetRPMs)
            return verified
        }
    }

    public func restoreAutomatic() throws -> HardwareSample {
        try lock.withLock {
            let zeroTarget = try encodeSMCFloat(0)

            // Preserve the ordering used by Apple's current Apple Silicon fan
            // hand-off: request automatic and clear stale targets before
            // releasing Ftst, then keep asserting automatic until read-back
            // confirms that thermalmonitord has reclaimed every fan.
            for limits in inventory.fans {
                let modeKey = Self.fanKey(modeTemplate, limits.index)
                try? transport.write(modeKey, bytes: [0])
                try? transport.write(Self.fanKey("F%dTg", limits.index), bytes: zeroTarget)
            }
            if hasForceTest { try retryWrite("Ftst", bytes: [0]) }

            if hasForceTest { Thread.sleep(forTimeInterval: 0.05) }
            let deadline = Date().addingTimeInterval(5)
            var lastDetail = "automatic mode did not latch"

            while Date() < deadline {
                var writeErrors: [String] = []
                for limits in inventory.fans {
                    let modeKey = Self.fanKey(modeTemplate, limits.index)
                    do { try transport.write(modeKey, bytes: [0]) }
                    catch { writeErrors.append("\(modeKey): \(error)") }

                    // Target zero is cleanup only; automatic/system mode is the
                    // safety boundary and firmware may immediately replace it.
                    try? transport.write(Self.fanKey("F%dTg", limits.index), bytes: zeroTarget)
                }
                if hasForceTest { try? transport.write("Ftst", bytes: [0]) }

                do {
                    let sample = try sampleUnlocked()
                    if sample.fans.allSatisfy({ $0.mode.isAutomatic }) {
                        return sample
                    }
                    lastDetail = sample.fans.map { "fan \($0.index)=\($0.mode.rawValue)" }
                        .joined(separator: ", ")
                } catch {
                    lastDetail = String(describing: error)
                }
                if !writeErrors.isEmpty { lastDetail += "; " + writeErrors.joined(separator: "; ") }
                Thread.sleep(forTimeInterval: 0.05)
            }

            throw HardwareError.verification("automatic mode did not latch: \(lastDetail)")
        }
    }

    public func applyMaximum() throws -> HardwareSample {
        try applyManual(targetRPMs: inventory.fans.map(\.maximumRPM))
    }

    private func sampleUnlocked() throws -> HardwareSample {
        var fans: [FanReading] = []
        for limits in inventory.fans {
            let actual = try Self.readRPM(transport, key: Self.fanKey("F%dAc", limits.index), allowZero: true)
            let target = try Self.readRPM(transport, key: Self.fanKey("F%dTg", limits.index), allowZero: true)
            let rawMode = try transport.read(Self.fanKey(modeTemplate, limits.index))
            guard let modeByte = rawMode.bytes.first else { throw HardwareError.invalidFanReading(limits.index) }
            let mode: FanMode = switch modeByte {
            case 0: .automatic
            case 1: .manual
            case 3: .system
            default: .unknown
            }
            guard actual >= 0, actual <= 25_000, target >= 0, target <= 25_000 else {
                throw HardwareError.invalidFanReading(limits.index)
            }
            fans.append(FanReading(index: limits.index, actualRPM: actual, targetRPM: target, mode: mode))
        }

        var temperatures: [String: Double] = [:]
        var failed: [String] = []
        for spec in sensorSpecs {
            do {
                let value = try Self.readTemperature(transport, spec: spec)
                guard value.isFinite, (-20...150).contains(value) else {
                    throw DomainError.invalidTemperature(value)
                }
                temperatures[spec.key] = value
            } catch {
                failed.append(spec.key)
            }
        }
        return try HardwareSample(fans: fans, temperatures: temperatures, failedSensorKeys: failed)
    }

    private func verifyManual(_ sample: HardwareSample, targets: [Int]) throws {
        guard sample.fans.count == targets.count, sample.fans.allSatisfy({ $0.mode == .manual }) else {
            throw HardwareError.verification("manual mode did not verify")
        }
        for (fan, target) in zip(sample.fans, targets) where abs(fan.targetRPM - target) > 100 {
            throw HardwareError.verification("fan \(fan.index) target \(fan.targetRPM), expected \(target)")
        }
    }

    private func retryWrite(_ key: String, bytes: [UInt8]) throws {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try transport.write(key, bytes: bytes)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw HardwareError.write("\(key): \(lastError.map(String.init(describing:)) ?? "unknown")")
    }

    private func enterManualMode() throws {
        let deadline = Date().addingTimeInterval(5)
        var pending = Set(inventory.fans.map(\.index))
        var lastErrors: [Int: String] = [:]

        while !pending.isEmpty, Date() < deadline {
            for index in pending.sorted() {
                let key = Self.fanKey(modeTemplate, index)
                do {
                    try transport.write(key, bytes: [1])
                    let readback = try transport.read(key)
                    if readback.bytes.first == 1 {
                        pending.remove(index)
                        lastErrors[index] = nil
                    }
                } catch {
                    lastErrors[index] = String(describing: error)
                }
            }
            if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }

        guard pending.isEmpty else {
            let detail = pending.sorted().map { index in
                "fan \(index)\(lastErrors[index].map { ": \($0)" } ?? "")"
            }.joined(separator: ", ")
            throw HardwareError.verification("manual mode did not latch: \(detail)")
        }
    }

    private func applyTargets(_ targets: [Int]) throws {
        let deadline = Date().addingTimeInterval(5)
        var pending = Set(inventory.fans.map(\.index))
        var lastReadbacks: [Int: Int] = [:]
        var lastErrors: [Int: String] = [:]

        while !pending.isEmpty, Date() < deadline {
            for index in pending.sorted() {
                let key = Self.fanKey("F%dTg", index)
                do {
                    try transport.write(key, bytes: encodeSMCFloat(Double(targets[index])))
                    let readback = try Self.readRPM(transport, key: key, allowZero: true)
                    lastReadbacks[index] = readback
                    if abs(readback - targets[index]) <= 100 {
                        pending.remove(index)
                        lastErrors[index] = nil
                    }
                } catch {
                    lastErrors[index] = String(describing: error)
                }
            }
            if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }

        guard pending.isEmpty else {
            let detail = pending.sorted().map { index in
                if let error = lastErrors[index] { return "fan \(index): \(error)" }
                return "fan \(index)=\(lastReadbacks[index].map(String.init) ?? "unreadable"), expected \(targets[index])"
            }.joined(separator: ", ")
            throw HardwareError.verification("fan targets did not latch: \(detail)")
        }
    }

    private static func readRPM(_ transport: SMCTransport, key: String, allowZero: Bool = false) throws -> Int {
        let value = try decodeSMCFloat(transport.read(key).bytes)
        guard value.isFinite, value <= 25_000, allowZero ? value >= 0 : value >= 100 else {
            throw HardwareError.read("invalid RPM value for \(key): \(value)")
        }
        return Int(value.rounded())
    }

    private static func readTemperature(_ transport: SMCTransport, spec: SensorSpec) throws -> Double {
        let value = try transport.read(spec.key)
        switch spec.encoding {
        case .float: return try decodeSMCFloat(value.bytes)
        case .ioFixed: return try decodeIOFixedTemperature(value.bytes)
        }
    }

    private static func fanKey(_ template: String, _ index: Int) -> String {
        // Inventory constrains indices to one decimal digit, so this always remains
        // a four-byte SMC key and never relies on a runtime precondition.
        String(format: template, index)
    }

    private static let knownSensors: [SensorSpec] = {
        var result: [SensorSpec] = []
        let cpu = [
            "TCDX", "TCHP", "TCMb", "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08",
            "Tp09", "Tp0A", "Tp0B", "Tp0C", "Tp0D", "Tp0F", "Tp0G", "Tp0H", "Tp0J", "Tp0L", "Tp0P",
            "Tp0S", "Tp0T", "Tp0W", "Tp0X", "Tp0b",
        ]
        let gpu = ["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j"]
        let memory = ["Tm02", "Tm06", "Tm08", "Tm09", "TRDX", "TMVR"]
        let storage = ["TH0x", "TH0A", "TH0B"]
        let power = ["TPDX"]
        let battery = ["TB0T"]
        let ambient = ["TAOL", "TA0P", "TS0P"]

        result += cpu.map { SensorSpec(key: $0, family: .cpu, limit: 100, required: true, encoding: .float) }
        result += gpu.map { SensorSpec(key: $0, family: .gpu, limit: 100, required: true, encoding: .float) }
        result += memory.map { SensorSpec(key: $0, family: .memory, limit: 90, required: true, encoding: .float) }
        result += storage.map { SensorSpec(key: $0, family: .storage, limit: 80, required: true, encoding: .float) }
        result += power.map { SensorSpec(key: $0, family: .power, limit: 90, required: true, encoding: .float) }
        result += battery.map { SensorSpec(key: $0, family: .battery, limit: 60, required: true, encoding: .float) }
        result += ambient.map { SensorSpec(key: $0, family: .ambient, limit: 100, required: false, encoding: .float) }
        result += ["TG0B", "TG0H", "TG0V"].map {
            SensorSpec(key: $0, family: .gpu, limit: 100, required: true, encoding: .ioFixed)
        }
        return result
    }()
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
