import Foundation

public enum KazeVersion {
    public static let current = "2.0.0-alpha.2"
    public static let protocolVersion = 7
    public static let minimumMacOS = "14.0"
}

public enum FanMode: String, Codable, Sendable, Equatable {
    case automatic
    case manual
    case system
    case unknown

    public var isAutomatic: Bool { self == .automatic || self == .system }
}

public struct FanLimits: Codable, Sendable, Equatable {
    public let index: Int
    public let minimumRPM: Int
    public let maximumRPM: Int

    public init(index: Int, minimumRPM: Int, maximumRPM: Int) throws {
        guard (0..<8).contains(index) else { throw DomainError.invalidFanIndex(index) }
        guard minimumRPM >= 100, maximumRPM <= 20_000, minimumRPM < maximumRPM else {
            throw DomainError.invalidFanLimits(index: index, minimum: minimumRPM, maximum: maximumRPM)
        }
        self.index = index
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
    }

    public func contains(_ rpm: Int) -> Bool {
        (minimumRPM...maximumRPM).contains(rpm)
    }
}

public struct FanReading: Codable, Sendable, Equatable {
    public let index: Int
    public let actualRPM: Int
    public let targetRPM: Int
    public let mode: FanMode

    public init(index: Int, actualRPM: Int, targetRPM: Int, mode: FanMode) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.mode = mode
    }
}

public enum SensorFamily: String, Codable, Sendable, Equatable {
    case cpu
    case gpu
    case memory
    case storage
    case power
    case battery
    case ambient
    case other
}

public struct SensorDescriptor: Codable, Sendable, Equatable {
    public let key: String
    public let family: SensorFamily
    public let safetyLimitCelsius: Double
    public let required: Bool

    public init(key: String, family: SensorFamily, safetyLimitCelsius: Double, required: Bool = true) throws {
        guard key.utf8.count == 4 else { throw DomainError.invalidSensorKey(key) }
        guard safetyLimitCelsius.isFinite, (40...120).contains(safetyLimitCelsius) else {
            throw DomainError.invalidTemperature(safetyLimitCelsius)
        }
        self.key = key
        self.family = family
        self.safetyLimitCelsius = safetyLimitCelsius
        self.required = required
    }
}

public struct HardwareInventory: Codable, Sendable, Equatable {
    public let fans: [FanLimits]
    public let sensors: [SensorDescriptor]

    public init(fans: [FanLimits], sensors: [SensorDescriptor]) throws {
        guard !fans.isEmpty, fans.count <= 8 else { throw DomainError.invalidFanCount(fans.count) }
        guard Set(fans.map(\.index)).count == fans.count else { throw DomainError.duplicateFanIndex }
        guard !sensors.isEmpty else { throw DomainError.noTemperatureSensors }
        guard sensors.contains(where: { $0.family == .cpu || $0.family == .gpu }) else {
            throw DomainError.noDieTemperatureSensor
        }
        self.fans = fans.sorted { $0.index < $1.index }
        self.sensors = sensors
    }
}

public struct HardwareSample: Codable, Sendable, Equatable {
    public let fans: [FanReading]
    public let temperatures: [String: Double]
    public let failedSensorKeys: [String]

    public init(fans: [FanReading], temperatures: [String: Double], failedSensorKeys: [String] = []) throws {
        guard !fans.isEmpty, fans.count <= 8 else { throw DomainError.invalidFanCount(fans.count) }
        guard Set(fans.map(\.index)).count == fans.count else { throw DomainError.duplicateFanIndex }
        for fan in fans {
            guard (0..<8).contains(fan.index),
                  (0...25_000).contains(fan.actualRPM),
                  (0...25_000).contains(fan.targetRPM) else {
                throw DomainError.invalidFanReading(fan.index)
            }
        }
        for (key, value) in temperatures {
            guard key.utf8.count == 4 else { throw DomainError.invalidSensorKey(key) }
            guard value.isFinite, (-20...150).contains(value) else {
                throw DomainError.invalidTemperature(value)
            }
        }
        guard failedSensorKeys.allSatisfy({ $0.utf8.count == 4 }) else {
            throw DomainError.invalidSensorKey(failedSensorKeys.first { $0.utf8.count != 4 } ?? "")
        }
        self.fans = fans.sorted { $0.index < $1.index }
        self.temperatures = temperatures
        self.failedSensorKeys = failedSensorKeys.sorted()
    }
}

public enum ProfileID: String, CaseIterable, Codable, Sendable {
    case performance
    case smart
}

public enum ControlIntent: Codable, Sendable, Equatable {
    case automatic
    case profile(ProfileID)
    case fixedRPM(Int)
    case maximum

    public var displayName: String {
        switch self {
        case .automatic: "Apple Automatic"
        case .profile(let profile): profile.rawValue.capitalized
        case .fixedRPM(let rpm): "Fixed \(rpm) RPM"
        case .maximum: "Maximum"
        }
    }
}

public enum ControllerMode: String, Codable, Sendable, Equatable {
    case starting
    case automatic
    case performance
    case smart
    case fixed
    case maximum
    case safetyMaximum
    case safetyCooling
    case failSafeAutomatic
    case failSafeMaximum
    case unrecoveredFault

    public var displayName: String {
        switch self {
        case .starting: "Starting"
        case .automatic: "Apple Automatic"
        case .performance: "Performance"
        case .smart: "Smart"
        case .fixed: "Fixed RPM"
        case .maximum: "Maximum"
        case .safetyMaximum: "Safety Maximum"
        case .safetyCooling: "Safety Cooling"
        case .failSafeAutomatic: "Fail-safe Automatic"
        case .failSafeMaximum: "Fail-safe Maximum"
        case .unrecoveredFault: "Unrecovered Fault"
        }
    }
}

public struct ControllerFault: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let occurredAtUptimeNanoseconds: UInt64

    public init(code: String, message: String, occurredAtUptimeNanoseconds: UInt64) {
        self.code = code
        self.message = message
        self.occurredAtUptimeNanoseconds = occurredAtUptimeNanoseconds
    }
}

public struct ControllerStatus: Codable, Sendable, Equatable {
    public let version: String
    public let mode: ControllerMode
    public let intent: ControlIntent
    public let leaseID: UUID?
    public let leaseExpiresAtUptimeNanoseconds: UInt64?
    public let inventory: HardwareInventory
    public let latestSample: HardwareSample?
    public let fault: ControllerFault?

    public init(
        version: String = KazeVersion.current,
        mode: ControllerMode,
        intent: ControlIntent,
        leaseID: UUID?,
        leaseExpiresAtUptimeNanoseconds: UInt64?,
        inventory: HardwareInventory,
        latestSample: HardwareSample?,
        fault: ControllerFault?
    ) {
        self.version = version
        self.mode = mode
        self.intent = intent
        self.leaseID = leaseID
        self.leaseExpiresAtUptimeNanoseconds = leaseExpiresAtUptimeNanoseconds
        self.inventory = inventory
        self.latestSample = latestSample
        self.fault = fault
    }
}

/// A compact, bounded telemetry record retained by the helper for graphing.
/// Temperatures are the hottest value in each sensor family; fan arrays follow
/// the inventory's stable, index-sorted order.
public struct TelemetrySample: Codable, Sendable, Equatable, Identifiable {
    public var id: UInt64 { sampledAtUptimeNanoseconds }

    public let sampledAtUptimeNanoseconds: UInt64
    public let mode: ControllerMode
    public let peakTemperatures: [SensorFamily: Double]
    public let fanActualRPMs: [Int]
    public let fanTargetRPMs: [Int]
    public let faultCode: String?

    public init(
        sampledAtUptimeNanoseconds: UInt64,
        mode: ControllerMode,
        peakTemperatures: [SensorFamily: Double],
        fanActualRPMs: [Int],
        fanTargetRPMs: [Int],
        faultCode: String?
    ) {
        self.sampledAtUptimeNanoseconds = sampledAtUptimeNanoseconds
        self.mode = mode
        self.peakTemperatures = peakTemperatures
        self.fanActualRPMs = fanActualRPMs
        self.fanTargetRPMs = fanTargetRPMs
        self.faultCode = faultCode
    }
}

public enum DomainError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidFanCount(Int)
    case invalidFanIndex(Int)
    case invalidFanReading(Int)
    case duplicateFanIndex
    case invalidFanLimits(index: Int, minimum: Int, maximum: Int)
    case invalidRPM(Int)
    case invalidSensorKey(String)
    case invalidTemperature(Double)
    case noTemperatureSensors
    case noDieTemperatureSensor
    case invalidLeaseDuration(Double)
    case invalidTelemetryWindow(Double)
    case invalidTelemetryPointLimit(Int)
    case controlOwnedByAnotherSession
    case leaseNotOwned
    case leaseExpired
    case hardwareFailure(String)

    public var description: String {
        switch self {
        case .invalidFanCount(let count): return "invalid fan count: \(count)"
        case .invalidFanIndex(let index): return "invalid fan index: \(index)"
        case .invalidFanReading(let index): return "invalid reading for fan \(index)"
        case .duplicateFanIndex: return "duplicate fan index"
        case .invalidFanLimits(let index, let minimum, let maximum):
            return "invalid limits for fan \(index): \(minimum)...\(maximum) RPM"
        case .invalidRPM(let rpm): return "invalid RPM: \(rpm)"
        case .invalidSensorKey(let key): return "invalid sensor key: \(key)"
        case .invalidTemperature(let value): return "invalid temperature: \(value)"
        case .noTemperatureSensors: return "no temperature sensors discovered"
        case .noDieTemperatureSensor: return "no CPU or GPU temperature sensor discovered"
        case .invalidLeaseDuration(let value): return "invalid lease duration: \(value)"
        case .invalidTelemetryWindow(let value): return "invalid telemetry window: \(value) seconds"
        case .invalidTelemetryPointLimit(let value): return "invalid telemetry point limit: \(value)"
        case .controlOwnedByAnotherSession: return "control is owned by another connection"
        case .leaseNotOwned: return "lease is not owned by this connection"
        case .leaseExpired: return "lease expired"
        case .hardwareFailure(let message): return "hardware failure: \(message)"
        }
    }
}

public protocol ThermalHardware: AnyObject, Sendable {
    var inventory: HardwareInventory { get }
    func sample() throws -> HardwareSample
    func applyManual(targetRPMs: [Int]) throws -> HardwareSample
    func restoreAutomatic() throws -> HardwareSample
    func applyMaximum() throws -> HardwareSample
}
