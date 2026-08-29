import Dispatch
import Foundation
import OSLog

public struct SafetyConfiguration: Sendable, Equatable {
    public let tickIntervalSeconds: Double
    public let sensorStaleSeconds: Double
    public let maximumLeaseSeconds: Double
    public let healthySamplesBeforeResume: Int
    public let thermalResumeHysteresisCelsius: Double
    public let thermalRecoveryRampRPMPerSecond: Double
    public let thermalRecoveryFloorFraction: Double
    public let targetToleranceRPM: Int
    public let fanResponseGraceSeconds: Double
    public let minimumFanResponseFraction: Double
    public let dieTemperatureSmoothingSeconds: Double
    public let profileFractionDeadband: Double
    public let smartRiseWindowSeconds: Double
    public let smartRiseDeadbandCelsiusPerSecond: Double
    public let smartRiseGainPerCelsiusPerSecond: Double
    public let smartRiseBoostCeiling: Double

    public init(
        tickIntervalSeconds: Double = 0.25,
        sensorStaleSeconds: Double = 2,
        maximumLeaseSeconds: Double = 30,
        healthySamplesBeforeResume: Int = 8,
        thermalResumeHysteresisCelsius: Double = 5,
        thermalRecoveryRampRPMPerSecond: Double = 1_000,
        thermalRecoveryFloorFraction: Double = 0.65,
        targetToleranceRPM: Int = 100,
        fanResponseGraceSeconds: Double = 5,
        minimumFanResponseFraction: Double = 0.5,
        dieTemperatureSmoothingSeconds: Double = 3,
        profileFractionDeadband: Double = 0.02,
        smartRiseWindowSeconds: Double = 2,
        smartRiseDeadbandCelsiusPerSecond: Double = 0.4,
        smartRiseGainPerCelsiusPerSecond: Double = 0.06,
        smartRiseBoostCeiling: Double = 0.12
    ) {
        self.tickIntervalSeconds = tickIntervalSeconds
        self.sensorStaleSeconds = sensorStaleSeconds
        self.maximumLeaseSeconds = maximumLeaseSeconds
        self.healthySamplesBeforeResume = healthySamplesBeforeResume
        self.thermalResumeHysteresisCelsius = thermalResumeHysteresisCelsius
        self.thermalRecoveryRampRPMPerSecond = thermalRecoveryRampRPMPerSecond
        self.thermalRecoveryFloorFraction = thermalRecoveryFloorFraction
        self.targetToleranceRPM = targetToleranceRPM
        self.fanResponseGraceSeconds = fanResponseGraceSeconds
        self.minimumFanResponseFraction = minimumFanResponseFraction
        self.dieTemperatureSmoothingSeconds = dieTemperatureSmoothingSeconds
        self.profileFractionDeadband = profileFractionDeadband
        self.smartRiseWindowSeconds = smartRiseWindowSeconds
        self.smartRiseDeadbandCelsiusPerSecond = smartRiseDeadbandCelsiusPerSecond
        self.smartRiseGainPerCelsiusPerSecond = smartRiseGainPerCelsiusPerSecond
        self.smartRiseBoostCeiling = smartRiseBoostCeiling
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

    private enum ThermalOverridePhase {
        case maximumCooling
        case rampingDown
    }

    private struct ThermalOverride {
        var phase: ThermalOverridePhase = .maximumCooling
        var consecutiveCoolSamples = 0
    }

    private let hardware: ThermalHardware
    private let configuration: SafetyConfiguration
    private let clock: UptimeClock
    private let logger = Logger(subsystem: "com.producerguy.kaze", category: "safety")
    private let queue = DispatchQueue(label: "com.producerguy.kaze.safety-controller", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private var intent: ControlIntent = .automatic
    private var mode: ControllerMode = .starting {
        didSet {
            if oldValue != mode { logModeTransitionLocked(from: oldValue, to: mode) }
        }
    }
    private var lease: Lease?
    private var latestSample: HardwareSample?
    private var temperatureCache: [String: CachedTemperature] = [:]
    private var fault: ControllerFault?
    private var recoverySamplesRemaining = 0
    private var thermalOverride: ThermalOverride?
    private var automaticThermalAdvisoryKey: String?
    private var sustainedAboveSince: UInt64?
    private var lastAppliedTargets: [Int]?
    private var lastCommandAt: UInt64?
    private var manualControlStartedAt: UInt64?
    private var smoothedDieTemperature: Double?
    private var smoothedDieTemperatureAt: UInt64?
    private var riseAnchorTemperature: Double?
    private var riseAnchorAt: UInt64?
    private var smartRiseBoost: Double = 0
    private var lastProfileFraction: Double?
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
            if lease != nil { logLeaseEndLocked(reason: "shutdown", now: clock()) }
            lease = nil
            intent = .automatic
            thermalOverride = nil
            automaticThermalAdvisoryKey = nil
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
                return try resetAutomaticLocked(
                    now: clock(),
                    reason: "explicit_automatic",
                    failureCode: "explicit-reset-failed"
                )
            }
            let ttl = try validatedLeaseNanoseconds(leaseSeconds)
            try validate(newIntent)
            let now = clock()
            if let current = lease {
                if current.expiresAt <= now {
                    expireLeaseLocked(now: now)
                } else if current.ownerSessionID != ownerSessionID {
                    throw DomainError.controlOwnedByAnotherSession
                } else {
                    logLeaseEndLocked(reason: "replaced_by_owner", now: now)
                }
            }
            guard fault == nil, recoverySamplesRemaining == 0 else {
                throw DomainError.hardwareFailure("controller is still validating its fail-safe state")
            }

            let id = UUID()
            intent = newIntent
            lease = Lease(id: id, ownerSessionID: ownerSessionID, expiresAt: now + ttl, ttlNanoseconds: ttl)
            logger.notice(
                "lease_acquired intent=\(newIntent.displayName, privacy: .public) ttl_ms=\(ttl / 1_000_000, privacy: .public)"
            )
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
            guard var current = lease else {
                logger.error("lease_renew_rejected reason=no_active_lease")
                throw DomainError.leaseNotOwned
            }
            guard current.id == leaseID,
                  current.ownerSessionID == ownerSessionID else {
                logger.error("lease_renew_rejected reason=not_owned")
                throw DomainError.leaseNotOwned
            }
            guard current.expiresAt > now else {
                expireLeaseLocked(now: now)
                logger.error("lease_renew_rejected reason=expired")
                throw DomainError.leaseExpired
            }
            current.expiresAt = now + current.ttlNanoseconds
            lease = current
            logger.info(
                "lease_renewed intent=\(self.intent.displayName, privacy: .public) ttl_ms=\(current.ttlNanoseconds / 1_000_000, privacy: .public)"
            )
            return statusLocked()
        }
    }

    /// Any authenticated client may request the thermally safe default. It is
    /// deliberately not owner-restricted so a recovery UI can always release fans.
    @discardableResult
    public func resetAutomatic() throws -> ControllerStatus {
        try queue.sync {
            try resetAutomaticLocked(
                now: clock(),
                reason: "explicit_automatic",
                failureCode: "explicit-reset-failed"
            )
        }
    }

    public func connectionClosed(_ sessionID: UUID) {
        queue.async { [weak self] in
            guard let self, self.lease?.ownerSessionID == sessionID else { return }
            _ = try? self.resetAutomaticLocked(
                now: self.clock(),
                reason: "connection_closed",
                failureCode: "connection-close-recovery-failed"
            )
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
            if shouldPreserveAppleAutomaticLocked(sample: sample) {
                if automaticThermalAdvisoryKey == nil {
                    logger.warning(
                        "automatic_thermal_advisory sensor=\(hot.key, privacy: .public) value=\(hot.value, privacy: .public) action=preserve_apple_automatic"
                    )
                }
                automaticThermalAdvisoryKey = hot.key
            } else {
                automaticThermalAdvisoryKey = nil
                enterThermalMaximumLocked(key: hot.key, value: hot.value, sample: sample, now: now)
                return
            }
        } else if let advisoryKey = automaticThermalAdvisoryKey {
            logger.notice(
                "automatic_thermal_advisory_clear sensor=\(advisoryKey, privacy: .public) temperatures=\(self.temperatureSummaryLocked(), privacy: .public)"
            )
            automaticThermalAdvisoryKey = nil
        }

        if thermalOverride != nil {
            continueThermalRecoveryLocked(sample: sample, now: now)
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

        // Die sensors jitter by a few degrees between 0.25 s ticks. Driving the curve
        // straight off the raw peak turned that jitter into audible fan hunting, so the
        // profile path runs on a low-pass filtered signal instead. The hard thermal net
        // (firstUnsafeSensorLocked) still reads raw values every tick, and a raw peak at or
        // above the curve ceiling bypasses the filter, so cooling headroom is unchanged.
        let smoothed = updateSmoothedDieTemperatureLocked(peak: peak, now: now)
        let controlTemperature = peak >= curve.ceilingTemperature ? max(smoothed, peak) : smoothed

        if controlTemperature <= curve.stopTemperature {
            sustainedAboveSince = nil
            resetSmartRiseAnchorLocked(temperature: smoothed, now: now)
            lastProfileFraction = nil
            ensureAutomaticLocked(sample: sample, now: now, reportedMode: profile.controllerMode)
            return
        }

        if controlTemperature < curve.startTemperature && !currentlyManual {
            sustainedAboveSince = nil
            resetSmartRiseAnchorLocked(temperature: smoothed, now: now)
            lastProfileFraction = nil
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

        var fraction = curve.fraction(at: controlTemperature)
        if profile == .smart {
            fraction = min(fraction + smartRiseBoostLocked(temperature: smoothed, now: now), 1)
        }
        fraction = holdProfileFractionLocked(fraction)

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
        let continuingOverride = thermalOverride != nil
        if lease != nil { logLeaseEndLocked(reason: "thermal_override", now: now) }
        lease = nil
        intent = .automatic
        if !continuingOverride {
            resetProfileStateLocked()
            thermalOverride = ThermalOverride()
            fault = ControllerFault(
                code: "thermal-override",
                message: "\(key) reached \(String(format: "%.1f", value))°C",
                occurredAtUptimeNanoseconds: now
            )
            let limit = hardware.inventory.sensors
                .first(where: { $0.key == key })?.safetyLimitCelsius ?? value
            logger.critical(
                "thermal_override_enter sensor=\(key, privacy: .public) value=\(value, privacy: .public) limit=\(limit, privacy: .public)"
            )
        } else {
            thermalOverride?.phase = .maximumCooling
            thermalOverride?.consecutiveCoolSamples = 0
        }
        ensureThermalMaximumLocked(sample: sample, now: now)
    }

    private func continueThermalRecoveryLocked(sample: HardwareSample, now: UInt64) {
        guard var override = thermalOverride else { return }

        guard temperaturesAreBelowThermalResumeThresholdLocked() else {
            if override.phase == .rampingDown || override.consecutiveCoolSamples > 0 {
                logger.notice(
                    "thermal_recovery_reset temperatures=\(self.temperatureSummaryLocked(), privacy: .public)"
                )
            }
            override.phase = .maximumCooling
            override.consecutiveCoolSamples = 0
            thermalOverride = override
            ensureThermalMaximumLocked(sample: sample, now: now)
            return
        }

        switch override.phase {
        case .maximumCooling:
            override.consecutiveCoolSamples += 1
            if override.consecutiveCoolSamples < configuration.healthySamplesBeforeResume {
                thermalOverride = override
                ensureThermalMaximumLocked(sample: sample, now: now)
                return
            }
            override.phase = .rampingDown
            thermalOverride = override
            lastCommandAt = now
            logger.notice(
                "thermal_recovery_begin cool_samples=\(override.consecutiveCoolSamples, privacy: .public) temperatures=\(self.temperatureSummaryLocked(), privacy: .public)"
            )
            mode = .safetyCooling

        case .rampingDown:
            thermalOverride = override
            applyThermalRecoveryRampLocked(sample: sample, now: now)
        }
    }

    private func ensureThermalMaximumLocked(sample: HardwareSample, now: UInt64) {
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

    private func applyThermalRecoveryRampLocked(sample: HardwareSample, now: UInt64) {
        let floors = hardware.inventory.fans.map { limits in
            let range = Double(limits.maximumRPM - limits.minimumRPM)
            return limits.minimumRPM + Int((range * configuration.thermalRecoveryFloorFraction).rounded())
        }
        let previousTargets = lastAppliedTargets ?? hardware.inventory.fans.map(\.maximumRPM)

        if zip(previousTargets, floors).allSatisfy({ previous, floor in previous <= floor }) {
            logger.notice(
                "thermal_recovery_handoff targets=\(previousTargets.map(String.init).joined(separator: ","), privacy: .public) temperatures=\(self.temperatureSummaryLocked(), privacy: .public)"
            )
            thermalOverride = nil
            recoverySamplesRemaining = 0
            fault = nil
            ensureAutomaticLocked(sample: sample, now: now)
            return
        }

        let elapsed = lastCommandAt.map { Double(now - $0) / 1_000_000_000 }
            ?? configuration.tickIntervalSeconds
        let maximumStep = max(
            Int((configuration.thermalRecoveryRampRPMPerSecond * min(max(elapsed, 0.01), 2)).rounded()),
            1
        )
        let targets = zip(previousTargets, floors).map { previous, floor in
            max(previous - maximumStep, floor)
        }
        applyTargetsLocked(
            targets,
            requestedMode: .safetyCooling,
            sample: sample,
            now: now,
            force: false
        )
    }

    private func enterFailSafeLocked(code: String, message: String, now: UInt64) {
        logger.error(
            "fail_safe code=\(code, privacy: .public) message=\(message, privacy: .public) temperatures=\(self.temperatureSummaryLocked(), privacy: .public)"
        )
        if lease != nil { logLeaseEndLocked(reason: "fail_safe_\(code)", now: now) }
        lease = nil
        intent = .automatic
        thermalOverride = nil
        automaticThermalAdvisoryKey = nil
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

    private func resetAutomaticLocked(
        now: UInt64,
        reason: String,
        failureCode: String
    ) throws -> ControllerStatus {
        logLeaseEndLocked(reason: reason, now: now)
        lease = nil
        intent = .automatic
        thermalOverride = nil
        automaticThermalAdvisoryKey = nil
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
            enterFailSafeLocked(code: failureCode, message: String(describing: error), now: now)
            throw DomainError.hardwareFailure(fault?.message ?? String(describing: error))
        }
    }

    private func expireLeaseLocked(now: UInt64) {
        logLeaseEndLocked(reason: "expired", now: now)
        lease = nil
        intent = .automatic
        thermalOverride = nil
        automaticThermalAdvisoryKey = nil
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

    private func temperaturesAreBelowThermalResumeThresholdLocked() -> Bool {
        for descriptor in hardware.inventory.sensors {
            guard let value = temperatureCache[descriptor.key]?.value else {
                if descriptor.required { return false }
                continue
            }
            let resumeThreshold = descriptor.safetyLimitCelsius
                - configuration.thermalResumeHysteresisCelsius
            if value > resumeThreshold { return false }
        }
        return true
    }

    private func shouldPreserveAppleAutomaticLocked(sample: HardwareSample) -> Bool {
        thermalOverride == nil
            && lease == nil
            && intent == .automatic
            && sample.fans.allSatisfy { $0.mode.isAutomatic }
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

    /// Exponential moving average over the peak die temperature. The time constant is in
    /// seconds, so the filter behaves identically whatever the tick interval happens to be.
    private func updateSmoothedDieTemperatureLocked(peak: Double, now: UInt64) -> Double {
        let timeConstant = configuration.dieTemperatureSmoothingSeconds
        guard timeConstant > 0,
              let previous = smoothedDieTemperature,
              let previousAt = smoothedDieTemperatureAt,
              now > previousAt
        else {
            smoothedDieTemperature = peak
            smoothedDieTemperatureAt = now
            return peak
        }
        let elapsed = min(Double(now - previousAt) / 1_000_000_000, 5)
        let value = previous + (peak - previous) * (1 - exp(-elapsed / timeConstant))
        smoothedDieTemperature = value
        smoothedDieTemperatureAt = now
        return value
    }

    private func resetSmartRiseAnchorLocked(temperature: Double, now: UInt64) {
        riseAnchorTemperature = temperature
        riseAnchorAt = now
        smartRiseBoost = 0
    }

    /// Anticipatory boost for the smart profile. It is measured over a multi-second window on
    /// the filtered signal and held between windows, so one noisy sample can no longer surge
    /// the fans and the boost steps at most once per window instead of four times a second.
    private func smartRiseBoostLocked(temperature: Double, now: UInt64) -> Double {
        guard let anchor = riseAnchorTemperature, let anchorAt = riseAnchorAt, now > anchorAt else {
            resetSmartRiseAnchorLocked(temperature: temperature, now: now)
            return 0
        }
        let elapsed = Double(now - anchorAt) / 1_000_000_000
        guard elapsed >= configuration.smartRiseWindowSeconds else { return smartRiseBoost }
        let risePerSecond = (temperature - anchor) / elapsed
        riseAnchorTemperature = temperature
        riseAnchorAt = now
        let excess = risePerSecond - configuration.smartRiseDeadbandCelsiusPerSecond
        guard excess > 0 else {
            smartRiseBoost = 0
            return 0
        }
        smartRiseBoost = min(
            excess * configuration.smartRiseGainPerCelsiusPerSecond,
            configuration.smartRiseBoostCeiling
        )
        return smartRiseBoost
    }

    /// Steady-state hold band. Without it the filtered curve output keeps drifting across the
    /// RPM tolerance every few ticks and the fans never settle on one audible speed.
    private func holdProfileFractionLocked(_ fraction: Double) -> Double {
        if let held = lastProfileFraction, abs(fraction - held) <= configuration.profileFractionDeadband {
            return held
        }
        lastProfileFraction = fraction
        return fraction
    }

    private func resetProfileStateLocked() {
        sustainedAboveSince = nil
        lastAppliedTargets = nil
        lastCommandAt = nil
        manualControlStartedAt = nil
        smoothedDieTemperature = nil
        smoothedDieTemperatureAt = nil
        riseAnchorTemperature = nil
        riseAnchorAt = nil
        smartRiseBoost = 0
        lastProfileFraction = nil
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

    private func logModeTransitionLocked(from oldMode: ControllerMode, to newMode: ControllerMode) {
        let fans = latestSample?.fans.map {
            "\($0.index):\($0.mode.rawValue):\($0.actualRPM)/\($0.targetRPM)"
        }.joined(separator: ",") ?? "none"
        let faultCode = fault?.code ?? "none"
        logger.notice(
            "mode_transition from=\(oldMode.rawValue, privacy: .public) to=\(newMode.rawValue, privacy: .public) intent=\(self.intent.displayName, privacy: .public) fault=\(faultCode, privacy: .public) temperatures=\(self.temperatureSummaryLocked(), privacy: .public) fans=\(fans, privacy: .public)"
        )
    }

    private func logLeaseEndLocked(reason: String, now: UInt64) {
        guard let lease else {
            logger.notice(
                "automatic_restore reason=\(reason, privacy: .public) lease=none"
            )
            return
        }
        let remaining: String
        if lease.expiresAt >= now {
            remaining = String((lease.expiresAt - now) / 1_000_000)
        } else {
            remaining = "-\((now - lease.expiresAt) / 1_000_000)"
        }
        logger.notice(
            "lease_ended reason=\(reason, privacy: .public) intent=\(self.intent.displayName, privacy: .public) remaining_ms=\(remaining, privacy: .public)"
        )
    }

    private func temperatureSummaryLocked() -> String {
        let ranked = temperatureCache
            .sorted { lhs, rhs in lhs.value.value > rhs.value.value }
            .prefix(5)
        guard !ranked.isEmpty else { return "none" }
        return ranked.map { key, cached in
            "\(key):\(String(format: "%.1f", cached.value))"
        }.joined(separator: ",")
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
            thermalResumeHysteresisCelsius: thermalResumeHysteresisCelsius.isFinite
                && (1...20).contains(thermalResumeHysteresisCelsius)
                ? thermalResumeHysteresisCelsius : 5,
            thermalRecoveryRampRPMPerSecond: thermalRecoveryRampRPMPerSecond.isFinite
                && (100...10_000).contains(thermalRecoveryRampRPMPerSecond)
                ? thermalRecoveryRampRPMPerSecond : 1_000,
            thermalRecoveryFloorFraction: thermalRecoveryFloorFraction.isFinite
                && (0.4...0.9).contains(thermalRecoveryFloorFraction)
                ? thermalRecoveryFloorFraction : 0.65,
            targetToleranceRPM: (0...1_000).contains(targetToleranceRPM)
                ? targetToleranceRPM : 100,
            fanResponseGraceSeconds: fanResponseGraceSeconds.isFinite && (1...30).contains(fanResponseGraceSeconds)
                ? fanResponseGraceSeconds : 5,
            minimumFanResponseFraction: minimumFanResponseFraction.isFinite
                && (0.25...1).contains(minimumFanResponseFraction)
                ? minimumFanResponseFraction : 0.5,
            dieTemperatureSmoothingSeconds: dieTemperatureSmoothingSeconds.isFinite
                && (0...30).contains(dieTemperatureSmoothingSeconds)
                ? dieTemperatureSmoothingSeconds : 3,
            profileFractionDeadband: profileFractionDeadband.isFinite
                && (0...0.1).contains(profileFractionDeadband)
                ? profileFractionDeadband : 0.02,
            smartRiseWindowSeconds: smartRiseWindowSeconds.isFinite
                && (0.25...30).contains(smartRiseWindowSeconds)
                ? smartRiseWindowSeconds : 2,
            smartRiseDeadbandCelsiusPerSecond: smartRiseDeadbandCelsiusPerSecond.isFinite
                && (0...5).contains(smartRiseDeadbandCelsiusPerSecond)
                ? smartRiseDeadbandCelsiusPerSecond : 0.4,
            smartRiseGainPerCelsiusPerSecond: smartRiseGainPerCelsiusPerSecond.isFinite
                && (0...0.5).contains(smartRiseGainPerCelsiusPerSecond)
                ? smartRiseGainPerCelsiusPerSecond : 0.06,
            smartRiseBoostCeiling: smartRiseBoostCeiling.isFinite
                && (0...0.5).contains(smartRiseBoostCeiling)
                ? smartRiseBoostCeiling : 0.12
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
