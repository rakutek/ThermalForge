import Dispatch
import Foundation

public struct SafetyConfiguration: Sendable, Equatable {
    public let tickIntervalSeconds: Double
    public let sensorStaleSeconds: Double
    public let maximumLeaseSeconds: Double
    public let healthySamplesBeforeResume: Int
    public let targetToleranceRPM: Int
    public let fanResponseGraceSeconds: Double
    public let minimumFanResponseFraction: Double

    public init(
        tickIntervalSeconds: Double = 0.25,
        sensorStaleSeconds: Double = 2,
        maximumLeaseSeconds: Double = 30,
        healthySamplesBeforeResume: Int = 8,
        targetToleranceRPM: Int = 100,
        fanResponseGraceSeconds: Double = 5,
        minimumFanResponseFraction: Double = 0.5
    ) {
        self.tickIntervalSeconds = tickIntervalSeconds
        self.sensorStaleSeconds = sensorStaleSeconds
        self.maximumLeaseSeconds = maximumLeaseSeconds
        self.healthySamplesBeforeResume = healthySamplesBeforeResume
        self.targetToleranceRPM = targetToleranceRPM
        self.fanResponseGraceSeconds = fanResponseGraceSeconds
        self.minimumFanResponseFraction = minimumFanResponseFraction
    }
}

/// Root-side safety controller. Every state transition and every SMC operation is
/// serialized on one queue; clients never mutate controller state directly.
public final class SafetyController: @unchecked Sendable {
    public typealias UptimeClock = @Sendable () -> UInt64

    private struct Lease {
        let id: UUID
        let ownerSessionID: UUID
        var expiresAt: UInt64
        let ttlNanoseconds: UInt64
    }

    private struct CachedTemperature {
        var value: Double
        var sampledAt: UInt64
    }

    private let hardware: ThermalHardware
    private let configuration: SafetyConfiguration
    private let clock: UptimeClock
    private let queue = DispatchQueue(label: "com.producerguy.kaze.safety-controller", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private var intent: ControlIntent = .automatic
    private var mode: ControllerMode = .starting
    private var lease: Lease?
    private var latestSample: HardwareSample?
    private var temperatureCache: [String: CachedTemperature] = [:]
    private var fault: ControllerFault?
    private var recoverySamplesRemaining = 0
    private var sustainedAboveSince: UInt64?
    private var lastAppliedTargets: [Int]?
    private var lastCommandAt: UInt64?
    private var manualControlStartedAt: UInt64?
    private var lastDieTemperature: Double?
    private var lastDieTemperatureAt: UInt64?
    private var started = false

    public init(
        hardware: ThermalHardware,
        configuration: SafetyConfiguration = SafetyConfiguration(),
        clock: @escaping UptimeClock = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.hardware = hardware
        self.configuration = configuration.sanitized
        self.clock = clock
    }

    deinit {
        timer?.cancel()
    }

    /// Establishes a known hardware state before the helper starts accepting XPC.
    /// A failed automatic reset falls back to verified maximum cooling and remains
    /// visible as a fault; the timer keeps retrying recovery.
    public func start(startTimer: Bool = true) {
        queue.sync {
            guard !started else { return }
            started = true
            enterFailSafeLocked(code: "startup-recovery", message: "establishing a verified startup state", now: clock())
            if startTimer { installTimerLocked() }
        }
    }

    public func shutdown() {
        queue.sync {
            timer?.cancel()
            timer = nil
            lease = nil
            intent = .automatic
            do {
                let sample = try hardware.restoreAutomatic()
                try verifyAutomatic(sample)
                latestSample = sample
                mode = .automatic
                fault = nil
            } catch {
                enterFailSafeLocked(code: "shutdown-recovery", message: String(describing: error), now: clock())
            }
            started = false
        }
    }

    @discardableResult
    public func acquire(
        intent newIntent: ControlIntent,
        ownerSessionID: UUID,
        leaseSeconds: Double
    ) throws -> ControllerStatus {
        try queue.sync {
            guard newIntent != .automatic else {
                return try resetAutomaticLocked(now: clock())
            }
            let ttl = try validatedLeaseNanoseconds(leaseSeconds)
            try validate(newIntent)
            let now = clock()
            if let current = lease {
                if current.expiresAt <= now {
                    expireLeaseLocked(now: now)
                } else if current.ownerSessionID != ownerSessionID {
                    throw DomainError.controlOwnedByAnotherSession
                }
            }
            guard fault == nil, recoverySamplesRemaining == 0 else {
                throw DomainError.hardwareFailure("controller is still validating its fail-safe state")
            }

            let id = UUID()
            intent = newIntent
            lease = Lease(id: id, ownerSessionID: ownerSessionID, expiresAt: now + ttl, ttlNanoseconds: ttl)
            resetProfileStateLocked()
            tickLocked(now: now, forceActuation: true)

            guard lease?.id == id else {
                throw DomainError.hardwareFailure(fault?.message ?? "control request was not applied")
            }
            return statusLocked()
        }
    }

    @discardableResult
    public func renew(leaseID: UUID, ownerSessionID: UUID) throws -> ControllerStatus {
        try queue.sync {
            let now = clock()
            guard var current = lease,
                  current.id == leaseID,
                  current.ownerSessionID == ownerSessionID
            else { throw DomainError.leaseNotOwned }
            guard current.expiresAt > now else {
                expireLeaseLocked(now: now)
                throw DomainError.leaseExpired
            }
            current.expiresAt = now + current.ttlNanoseconds
            lease = current
            return statusLocked()
        }
    }

    /// Any authenticated client may request the thermally safe default. It is
    /// deliberately not owner-restricted so a recovery UI can always release fans.
    @discardableResult
    public func resetAutomatic() throws -> ControllerStatus {
        try queue.sync { try resetAutomaticLocked(now: clock()) }
    }

    public func connectionClosed(_ sessionID: UUID) {
        queue.async { [weak self] in
            guard let self, self.lease?.ownerSessionID == sessionID else { return }
            _ = try? self.resetAutomaticLocked(now: self.clock())
        }
    }

    public func status() -> ControllerStatus {
        queue.sync { statusLocked() }
    }

    /// Deterministic entry point used by fault-injection tests and wake handling.
    public func tickNow() {
        queue.sync { tickLocked(now: clock(), forceActuation: false) }
    }

    /// Sleep/wake invalidates assumptions about SMC state. Drop the lease and
    /// re-establish automatic; the client must explicitly acquire control again.
    public func handleWake() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastAppliedTargets = nil
            self.enterFailSafeLocked(code: "wake-recovery", message: "revalidating SMC after wake", now: self.clock())
        }
    }

    private func installTimerLocked() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + configuration.tickIntervalSeconds,
            repeating: configuration.tickIntervalSeconds,
            leeway: .milliseconds(25)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.tickLocked(now: self.clock(), forceActuation: false)
        }
        source.resume()
        timer = source
    }

    private func tickLocked(now: UInt64, forceActuation: Bool) {
        if let lease, lease.expiresAt <= now {
            expireLeaseLocked(now: now)
            return
        }

        let sample: HardwareSample
        do {
            sample = try hardware.sample()
            latestSample = sample
            updateTemperatureCacheLocked(sample: sample, now: now)
        } catch {
            enterFailSafeLocked(code: "sample-failed", message: String(describing: error), now: now)
            return
        }

        let staleSensors = staleRequiredSensorsLocked(now: now)
        guard staleSensors.isEmpty else {
            enterFailSafeLocked(
                code: "sensor-stale",
                message: "required sensors are stale: \(staleSensors.joined(separator: ", "))",
                now: now
            )
            return
        }

        if let hot = firstUnsafeSensorLocked() {
            enterThermalMaximumLocked(key: hot.key, value: hot.value, sample: sample, now: now)
            return
        }

        if recoverySamplesRemaining > 0 {
            recoverySamplesRemaining -= 1
            ensureAutomaticLocked(sample: sample, now: now)
            return
        }
        if fault != nil { fault = nil }

        switch intent {
        case .automatic:
            ensureAutomaticLocked(sample: sample, now: now)
        case .maximum:
            applyTargetsLocked(
                hardware.inventory.fans.map(\.maximumRPM),
                requestedMode: .maximum,
                sample: sample,
                now: now,
                force: forceActuation
            )
        case .fixedRPM(let rpm):
            applyTargetsLocked(
                Array(repeating: rpm, count: hardware.inventory.fans.count),
                requestedMode: .fixed,
                sample: sample,
                now: now,
                force: forceActuation
            )
        case .profile(let profile):
            applyProfileLocked(profile, sample: sample, now: now, force: forceActuation)
        }
    }

    private func applyProfileLocked(_ profile: ProfileID, sample: HardwareSample, now: UInt64, force: Bool) {
        let dieTemperatures = hardware.inventory.sensors
            .filter { $0.family == .cpu || $0.family == .gpu }
            .compactMap { temperatureCache[$0.key]?.value }
        guard let peak = dieTemperatures.max() else {
            enterFailSafeLocked(code: "die-sensor-missing", message: "no fresh die temperature", now: now)
            return
        }

        let curve: ProfileCurve
        do {
            curve = try profile.curve
        } catch {
            enterFailSafeLocked(code: "invalid-profile", message: String(describing: error), now: now)
            return
        }
        let currentlyManual = sample.fans.allSatisfy { $0.mode == .manual }

        if peak <= curve.stopTemperature {
            sustainedAboveSince = nil
            lastDieTemperature = peak
            lastDieTemperatureAt = now
            ensureAutomaticLocked(sample: sample, now: now, reportedMode: profile.controllerMode)
            return
        }

        if peak < curve.startTemperature && !currentlyManual {
            sustainedAboveSince = nil
            lastDieTemperature = peak
            lastDieTemperatureAt = now
            ensureAutomaticLocked(sample: sample, now: now, reportedMode: profile.controllerMode)
            return
        }

        if !currentlyManual {
            if sustainedAboveSince == nil { sustainedAboveSince = now }
            let required = nanoseconds(curve.sustainedSeconds)
            guard now >= (sustainedAboveSince ?? now) + required else {
                ensureAutomaticLocked(sample: sample, now: now, reportedMode: profile.controllerMode)
                return
            }
        }

        var fraction = curve.fraction(at: peak)
        if profile == .smart,
           let previous = lastDieTemperature,
           let previousAt = lastDieTemperatureAt,
           now > previousAt {
            let elapsed = Double(now - previousAt) / 1_000_000_000
            let risePerSecond = (peak - previous) / elapsed
            if risePerSecond > 0 {
                fraction = min(fraction + min(risePerSecond * 0.08, 0.25), 1)
            }
        }
        lastDieTemperature = peak
        lastDieTemperatureAt = now

        let elapsedSinceCommand = lastCommandAt.map { Double(now - $0) / 1_000_000_000 }
            ?? configuration.tickIntervalSeconds
        let elapsed = min(max(elapsedSinceCommand, 0.01), 2)

        var targets: [Int] = []
        for (offset, limits) in hardware.inventory.fans.enumerated() {
            let range = Double(limits.maximumRPM - limits.minimumRPM)
            var target = Double(limits.minimumRPM) + range * fraction
            let previous = Double(lastAppliedTargets?[safe: offset] ?? sample.fans[safe: offset]?.targetRPM ?? limits.minimumRPM)
            let rate = target >= previous ? curve.rampUpRPMPerSecond : curve.rampDownRPMPerSecond
            let delta = rate * elapsed
            target = target >= previous ? min(target, previous + delta) : max(target, previous - delta)
            targets.append(min(max(Int(target.rounded()), limits.minimumRPM), limits.maximumRPM))
        }

        applyTargetsLocked(targets, requestedMode: profile.controllerMode, sample: sample, now: now, force: force)
    }

    private func applyTargetsLocked(
        _ targets: [Int],
        requestedMode: ControllerMode,
        sample: HardwareSample,
        now: UInt64,
        force: Bool
    ) {
        if let previousTargets = lastAppliedTargets {
            do {
                try verifyFanResponse(sample, expectedTargets: previousTargets, now: now)
            } catch {
                enterFailSafeLocked(code: "fan-response-failed", message: String(describing: error), now: now)
                return
            }
        }

        let alreadyVerified = (try? verifyManual(sample, expectedTargets: targets)) != nil
        let materiallyChanged = zip(targets, lastAppliedTargets ?? []).contains {
            abs($0.0 - $0.1) > configuration.targetToleranceRPM
        } || lastAppliedTargets?.count != targets.count
        guard force || !alreadyVerified || materiallyChanged else {
            mode = requestedMode
            return
        }

        do {
            let verified = try hardware.applyManual(targetRPMs: targets)
            try verifyManual(verified, expectedTargets: targets)
            latestSample = verified
            lastAppliedTargets = targets
            lastCommandAt = now
            if manualControlStartedAt == nil { manualControlStartedAt = now }
            mode = requestedMode
        } catch {
            enterFailSafeLocked(code: "actuation-failed", message: String(describing: error), now: now)
        }
    }

    private func ensureAutomaticLocked(
        sample: HardwareSample,
        now: UInt64,
        reportedMode: ControllerMode = .automatic
    ) {
        if (try? verifyAutomatic(sample)) != nil {
            mode = fault == nil ? reportedMode : .failSafeAutomatic
            lastAppliedTargets = nil
            manualControlStartedAt = nil
            return
        }
        do {
            let verified = try hardware.restoreAutomatic()
            try verifyAutomatic(verified)
            latestSample = verified
            lastAppliedTargets = nil
            manualControlStartedAt = nil
            mode = fault == nil ? reportedMode : .failSafeAutomatic
        } catch {
            enterFailSafeLocked(code: "automatic-recovery-failed", message: String(describing: error), now: now)
        }
    }

    private func enterThermalMaximumLocked(key: String, value: Double, sample: HardwareSample, now: UInt64) {
        let continuingOverride = mode == .safetyMaximum && fault?.code == "thermal-override"
        lease = nil
        intent = .automatic
        if !continuingOverride { resetProfileStateLocked() }
        recoverySamplesRemaining = configuration.healthySamplesBeforeResume
        fault = ControllerFault(
            code: "thermal-override",
            message: "\(key) reached \(String(format: "%.1f", value))°C",
            occurredAtUptimeNanoseconds: now
        )

        let targets = hardware.inventory.fans.map(\.maximumRPM)
        if (try? verifyManual(sample, expectedTargets: targets)) != nil {
            if manualControlStartedAt == nil { manualControlStartedAt = now }
            do {
                try verifyFanResponse(sample, expectedTargets: targets, now: now)
            } catch {
                enterFailSafeLocked(code: "fan-response-failed", message: String(describing: error), now: now)
                return
            }
            latestSample = sample
            lastAppliedTargets = targets
            mode = .safetyMaximum
            return
        }

        do {
            let verified = try hardware.applyMaximum()
            try verifyManual(verified, expectedTargets: targets)
            latestSample = verified
            lastAppliedTargets = targets
            lastCommandAt = now
            if manualControlStartedAt == nil { manualControlStartedAt = now }
            mode = .safetyMaximum
        } catch {
            enterFailSafeLocked(code: "maximum-failed", message: String(describing: error), now: now)
        }
    }

    private func enterFailSafeLocked(code: String, message: String, now: UInt64) {
        lease = nil
        intent = .automatic
        resetProfileStateLocked()
        fault = ControllerFault(code: code, message: message, occurredAtUptimeNanoseconds: now)
        recoverySamplesRemaining = configuration.healthySamplesBeforeResume

        do {
            let automatic = try hardware.restoreAutomatic()
            try verifyAutomatic(automatic)
            latestSample = automatic
            mode = .failSafeAutomatic
            return
        } catch {
            let automaticError = String(describing: error)
            do {
                let maximum = try hardware.applyMaximum()
                try verifyManual(maximum, expectedTargets: hardware.inventory.fans.map(\.maximumRPM))
                latestSample = maximum
                lastAppliedTargets = hardware.inventory.fans.map(\.maximumRPM)
                mode = .failSafeMaximum
                fault = ControllerFault(
                    code: code,
                    message: "\(message); automatic recovery failed: \(automaticError); maximum cooling applied",
                    occurredAtUptimeNanoseconds: now
                )
            } catch {
                mode = .unrecoveredFault
                fault = ControllerFault(
                    code: "unrecovered-\(code)",
                    message: "\(message); automatic recovery failed: \(automaticError); maximum cooling failed: \(error)",
                    occurredAtUptimeNanoseconds: now
                )
            }
        }
    }

    private func resetAutomaticLocked(now: UInt64) throws -> ControllerStatus {
        lease = nil
        intent = .automatic
        resetProfileStateLocked()
        do {
            let sample = try hardware.restoreAutomatic()
            try verifyAutomatic(sample)
            latestSample = sample
            mode = .automatic
            fault = nil
            recoverySamplesRemaining = 0
            return statusLocked()
        } catch {
            enterFailSafeLocked(code: "explicit-reset-failed", message: String(describing: error), now: now)
            throw DomainError.hardwareFailure(fault?.message ?? String(describing: error))
        }
    }

    private func expireLeaseLocked(now: UInt64) {
        lease = nil
        intent = .automatic
        resetProfileStateLocked()
        do {
            let sample = try hardware.restoreAutomatic()
            try verifyAutomatic(sample)
            latestSample = sample
            mode = .automatic
        } catch {
            enterFailSafeLocked(code: "lease-expiry-recovery", message: String(describing: error), now: now)
        }
    }

    private func updateTemperatureCacheLocked(sample: HardwareSample, now: UInt64) {
        let expected = Set(hardware.inventory.sensors.map(\.key))
        for (key, value) in sample.temperatures where expected.contains(key) && value.isFinite {
            temperatureCache[key] = CachedTemperature(value: value, sampledAt: now)
        }
    }

    private func staleRequiredSensorsLocked(now: UInt64) -> [String] {
        let staleAfter = nanoseconds(configuration.sensorStaleSeconds)
        return hardware.inventory.sensors.compactMap { sensor in
            guard sensor.required else { return nil }
            guard let cached = temperatureCache[sensor.key], now >= cached.sampledAt,
                  now - cached.sampledAt <= staleAfter else { return sensor.key }
            return nil
        }
    }

    private func firstUnsafeSensorLocked() -> (key: String, value: Double)? {
        for descriptor in hardware.inventory.sensors {
            if let value = temperatureCache[descriptor.key]?.value,
               value >= descriptor.safetyLimitCelsius {
                return (descriptor.key, value)
            }
        }
        return nil
    }

    private func verifyAutomatic(_ sample: HardwareSample) throws {
        guard sample.fans.count == hardware.inventory.fans.count,
              zip(sample.fans, hardware.inventory.fans).allSatisfy({ reading, limits in
                  reading.index == limits.index && reading.mode.isAutomatic
              }) else {
            throw DomainError.hardwareFailure("automatic mode did not verify")
        }
    }

    private func verifyManual(_ sample: HardwareSample, expectedTargets: [Int]) throws {
        guard sample.fans.count == expectedTargets.count,
              sample.fans.count == hardware.inventory.fans.count,
              zip(sample.fans, hardware.inventory.fans).allSatisfy({ reading, limits in
                  reading.index == limits.index && reading.mode == .manual
              }) else {
            throw DomainError.hardwareFailure("manual mode did not verify")
        }
        for (fan, expected) in zip(sample.fans, expectedTargets) {
            guard abs(fan.targetRPM - expected) <= configuration.targetToleranceRPM else {
                throw DomainError.hardwareFailure(
                    "fan \(fan.index) target read-back was \(fan.targetRPM), expected \(expected)"
                )
            }
        }
    }

    private func verifyFanResponse(_ sample: HardwareSample, expectedTargets: [Int], now: UInt64) throws {
        guard let startedAt = manualControlStartedAt,
              now >= startedAt,
              Double(now - startedAt) / 1_000_000_000 >= configuration.fanResponseGraceSeconds else {
            return
        }
        for (fan, expected) in zip(sample.fans, expectedTargets) {
            let minimumActual = Int((Double(expected) * configuration.minimumFanResponseFraction).rounded(.down))
            guard fan.actualRPM >= minimumActual else {
                throw DomainError.hardwareFailure(
                    "fan \(fan.index) actual read-back was \(fan.actualRPM) RPM, expected at least \(minimumActual) RPM"
                )
            }
        }
    }

    private func validate(_ intent: ControlIntent) throws {
        switch intent {
        case .automatic, .profile, .maximum:
            return
        case .fixedRPM(let rpm):
            guard hardware.inventory.fans.allSatisfy({ $0.contains(rpm) }) else {
                throw DomainError.invalidRPM(rpm)
            }
        }
    }

    private func validatedLeaseNanoseconds(_ seconds: Double) throws -> UInt64 {
        guard seconds.isFinite, seconds >= 5, seconds <= configuration.maximumLeaseSeconds else {
            throw DomainError.invalidLeaseDuration(seconds)
        }
        return nanoseconds(seconds)
    }

    private func resetProfileStateLocked() {
        sustainedAboveSince = nil
        lastAppliedTargets = nil
        lastCommandAt = nil
        manualControlStartedAt = nil
        lastDieTemperature = nil
        lastDieTemperatureAt = nil
    }

    private func statusLocked() -> ControllerStatus {
        ControllerStatus(
            mode: mode,
            intent: intent,
            leaseID: lease?.id,
            leaseExpiresAtUptimeNanoseconds: lease?.expiresAt,
            inventory: hardware.inventory,
            latestSample: latestSample,
            fault: fault
        )
    }

    private func nanoseconds(_ seconds: Double) -> UInt64 {
        UInt64((seconds * 1_000_000_000).rounded())
    }
}

private extension SafetyConfiguration {
    var sanitized: SafetyConfiguration {
        SafetyConfiguration(
            tickIntervalSeconds: tickIntervalSeconds.isFinite && (0.05...5).contains(tickIntervalSeconds)
                ? tickIntervalSeconds : 0.25,
            sensorStaleSeconds: sensorStaleSeconds.isFinite && (0.5...10).contains(sensorStaleSeconds)
                ? sensorStaleSeconds : 2,
            maximumLeaseSeconds: maximumLeaseSeconds.isFinite && (5...300).contains(maximumLeaseSeconds)
                ? maximumLeaseSeconds : 30,
            healthySamplesBeforeResume: (0...100).contains(healthySamplesBeforeResume)
                ? healthySamplesBeforeResume : 8,
            targetToleranceRPM: (0...1_000).contains(targetToleranceRPM)
                ? targetToleranceRPM : 100,
            fanResponseGraceSeconds: fanResponseGraceSeconds.isFinite && (1...30).contains(fanResponseGraceSeconds)
                ? fanResponseGraceSeconds : 5,
            minimumFanResponseFraction: minimumFanResponseFraction.isFinite
                && (0.25...1).contains(minimumFanResponseFraction)
                ? minimumFanResponseFraction : 0.5
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
