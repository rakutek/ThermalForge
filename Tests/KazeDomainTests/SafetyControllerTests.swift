import XCTest
@testable import KazeDomain

final class SafetyControllerTests: XCTestCase {
    func testStartupAlwaysEstablishesVerifiedAutomaticMode() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)

        controller.start(startTimer: false)

        XCTAssertEqual(hardware.restoreCount, 1)
        XCTAssertEqual(controller.status().mode, .failSafeAutomatic)
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode.isAutomatic })
    }

    func testUnsafeNonDieSensorForcesMaximumCooling() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        _ = try controller.acquire(intent: .fixedRPM(2_000), ownerSessionID: UUID(), leaseSeconds: 20)

        hardware.temperatures["TH0A"] = 81
        controller.tickNow()

        XCTAssertEqual(controller.status().mode, .safetyMaximum)
        XCTAssertEqual(hardware.maximumCount, 1)
        XCTAssertEqual(hardware.currentFans.map(\.targetRPM), [6_000, 5_500])
    }

    func testOverLimitSensorDoesNotSeizeVerifiedAppleAutomaticControl() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()

        hardware.temperatures["TH0A"] = 81
        controller.tickNow()

        XCTAssertEqual(controller.status().mode, .automatic)
        XCTAssertNil(controller.status().fault)
        XCTAssertEqual(hardware.maximumCount, 0)
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode.isAutomatic })
    }

    func testThermalOverrideRevokesLeaseAndRequiresExplicitReacquisition() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        _ = try controller.acquire(intent: .fixedRPM(2_000), ownerSessionID: UUID(), leaseSeconds: 20)

        hardware.temperatures["TH0A"] = 81
        controller.tickNow()

        XCTAssertEqual(controller.status().mode, .safetyMaximum)
        XCTAssertEqual(controller.status().intent, .automatic)
        XCTAssertNil(controller.status().leaseID)

        hardware.temperatures["TH0A"] = 70
        controller.tickNow()

        XCTAssertEqual(controller.status().mode, .safetyCooling)
        XCTAssertEqual(controller.status().intent, .automatic)
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode == .manual })

        for _ in 0..<4 where controller.status().mode != .automatic {
            clock.now += 1_000_000_000
            controller.tickNow()
        }

        XCTAssertEqual(controller.status().mode, .automatic)
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode.isAutomatic })
    }

    func testThermalRecoveryRequiresHysteresisAndConsecutiveCoolSamples() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(
            hardware,
            healthySamplesBeforeResume: 2,
            thermalRecoveryRampRPMPerSecond: 10_000
        )
        controller.start(startTimer: false)
        for _ in 0..<3 {
            clock.now += 250_000_000
            controller.tickNow()
        }
        _ = try controller.acquire(intent: .fixedRPM(2_000), ownerSessionID: UUID(), leaseSeconds: 20)
        let restoresBeforeOverride = hardware.restoreCount

        hardware.temperatures["TH0A"] = 81
        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertEqual(controller.status().mode, .safetyMaximum)
        XCTAssertEqual(hardware.maximumCount, 1)

        // Below the hard limit but above the 5°C release hysteresis: remain at
        // maximum instead of handing control back and oscillating.
        hardware.temperatures["TH0A"] = 79
        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertEqual(controller.status().mode, .safetyMaximum)
        XCTAssertEqual(hardware.restoreCount, restoresBeforeOverride)
        XCTAssertEqual(hardware.maximumCount, 1)

        // One cool sample is insufficient, and a warmer sample resets the run.
        hardware.temperatures["TH0A"] = 74
        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertEqual(controller.status().mode, .safetyMaximum)

        hardware.temperatures["TH0A"] = 79
        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertEqual(controller.status().mode, .safetyMaximum)

        hardware.temperatures["TH0A"] = 74
        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertEqual(controller.status().mode, .safetyMaximum)

        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertEqual(controller.status().mode, .safetyCooling)
        XCTAssertEqual(hardware.restoreCount, restoresBeforeOverride)

        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertEqual(controller.status().mode, .safetyCooling)
        XCTAssertLessThan(hardware.currentFans[0].targetRPM, 6_000)
        XCTAssertLessThan(hardware.currentFans[1].targetRPM, 5_500)

        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertEqual(controller.status().mode, .automatic)
        XCTAssertNil(controller.status().fault)
        XCTAssertEqual(hardware.restoreCount, restoresBeforeOverride + 1)
    }

    func testThermalRecoveryReturnsDirectlyToMaximumWhenTemperatureRebounds() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        _ = try controller.acquire(intent: .fixedRPM(2_000), ownerSessionID: UUID(), leaseSeconds: 20)

        hardware.temperatures["TH0A"] = 81
        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertEqual(controller.status().mode, .safetyMaximum)

        hardware.temperatures["TH0A"] = 70
        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertEqual(controller.status().mode, .safetyCooling)

        clock.now += 250_000_000
        controller.tickNow()
        XCTAssertLessThan(hardware.currentFans[0].targetRPM, 6_000)

        hardware.temperatures["TH0A"] = 79
        clock.now += 250_000_000
        controller.tickNow()

        XCTAssertEqual(controller.status().mode, .safetyMaximum)
        XCTAssertEqual(hardware.currentFans.map(\.targetRPM), [6_000, 5_500])
        XCTAssertEqual(hardware.maximumCount, 2)
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode == .manual })
    }

    func testStaleRequiredSensorRestoresAutomatic() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()

        hardware.temperatures.removeValue(forKey: "TC0P")
        clock.now += 3_000_000_000
        controller.tickNow()

        XCTAssertEqual(controller.status().mode, .failSafeAutomatic)
        XCTAssertEqual(controller.status().fault?.code, "sensor-stale")
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode.isAutomatic })
    }

    func testNonFiniteLeaseIsRejected() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)

        XCTAssertThrowsError(
            try controller.acquire(intent: .maximum, ownerSessionID: UUID(), leaseSeconds: .nan)
        ) { error in
            guard case DomainError.invalidLeaseDuration = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRPMMustFitEveryFan() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()

        XCTAssertThrowsError(
            try controller.acquire(intent: .fixedRPM(5_800), ownerSessionID: UUID(), leaseSeconds: 20)
        ) { error in
            XCTAssertEqual(error as? DomainError, .invalidRPM(5_800))
        }
    }

    func testEachProfileReportsItsOwnModeImmediately() throws {
        for profile in ProfileID.allCases {
            let hardware = try MockHardware()
            let (controller, _) = makeController(hardware)
            controller.start(startTimer: false)
            controller.tickNow()

            let status = try controller.acquire(
                intent: .profile(profile),
                ownerSessionID: UUID(),
                leaseSeconds: 20
            )

            XCTAssertEqual(status.mode, profile.controllerMode)
            XCTAssertEqual(status.mode.displayName, profile.rawValue.capitalized)
            XCTAssertEqual(status.intent, .profile(profile))
        }
    }

    func testSmartProfileDoesNotChaseDieSensorJitter() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        hardware.temperatures["TC0P"] = 68
        controller.tickNow()
        _ = try controller.acquire(intent: .profile(.smart), ownerSessionID: UUID(), leaseSeconds: 30)

        // Settle: the profile debounces for sustainedSeconds before taking manual control,
        // then the ramp limiter needs a few more ticks to reach the curve target.
        for index in 0..<40 {
            clock.now += 250_000_000
            hardware.temperatures["TC0P"] = index.isMultiple(of: 2) ? 68 : 71
            controller.tickNow()
        }

        let writesBeforeObservation = hardware.manualCount
        var observed: [Int] = []
        for index in 0..<24 {
            clock.now += 250_000_000
            hardware.temperatures["TC0P"] = index.isMultiple(of: 2) ? 68 : 71
            controller.tickNow()
            observed.append(hardware.currentFans[0].targetRPM)
        }

        XCTAssertEqual(controller.status().mode, .smart)
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode == .manual })
        let spread = (observed.max() ?? 0) - (observed.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 100, "smart chased die sensor jitter: \(observed)")
        XCTAssertLessThanOrEqual(hardware.manualCount - writesBeforeObservation, 1)
    }

    func testSmartProfileStillRampsUpOnSustainedTemperatureRise() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        hardware.temperatures["TC0P"] = 60
        controller.tickNow()
        _ = try controller.acquire(intent: .profile(.smart), ownerSessionID: UUID(), leaseSeconds: 30)

        for _ in 0..<40 {
            clock.now += 250_000_000
            controller.tickNow()
        }
        let settled = hardware.currentFans[0].targetRPM

        for index in 0..<24 {
            clock.now += 250_000_000
            hardware.temperatures["TC0P"] = 60 + Double(index + 1)
            controller.tickNow()
        }

        XCTAssertEqual(controller.status().mode, .smart)
        XCTAssertGreaterThan(hardware.currentFans[0].targetRPM, settled + 1_500)
    }

    func testActuationFailureNeverClaimsManualSuccess() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        hardware.failManual = true

        XCTAssertThrowsError(
            try controller.acquire(intent: .maximum, ownerSessionID: UUID(), leaseSeconds: 20)
        )
        XCTAssertEqual(controller.status().mode, .failSafeAutomatic)
        XCTAssertNil(controller.status().leaseID)
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode.isAutomatic })
    }

    func testAutomaticFailureFallsBackToMaximum() throws {
        let hardware = try MockHardware()
        hardware.failAutomatic = true
        let (controller, _) = makeController(hardware)

        controller.start(startTimer: false)

        XCTAssertEqual(controller.status().mode, .failSafeMaximum)
        XCTAssertEqual(hardware.maximumCount, 1)
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode == .manual })
    }

    func testBothStartupRecoveryStagesFailClosed() throws {
        let hardware = try MockHardware()
        hardware.failAutomatic = true
        hardware.failMaximum = true
        let (controller, _) = makeController(hardware)

        controller.start(startTimer: false)

        XCTAssertEqual(controller.status().mode, .unrecoveredFault)
        XCTAssertNil(controller.status().leaseID)
        XCTAssertEqual(controller.status().fault?.code, "unrecovered-startup-recovery")
    }

    func testReadbackMismatchTriggersRecovery() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        hardware.lieAboutManualReadback = true

        XCTAssertThrowsError(
            try controller.acquire(intent: .maximum, ownerSessionID: UUID(), leaseSeconds: 20)
        )
        XCTAssertEqual(controller.status().mode, .failSafeAutomatic)
        XCTAssertNil(controller.status().leaseID)
    }

    func testFanThatDoesNotPhysicallyRespondTriggersRecoveryAfterGracePeriod() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        hardware.lieAboutActualReadback = true
        _ = try controller.acquire(intent: .maximum, ownerSessionID: UUID(), leaseSeconds: 20)

        clock.now += 6_000_000_000
        controller.tickNow()

        XCTAssertEqual(controller.status().mode, .failSafeAutomatic)
        XCTAssertEqual(controller.status().fault?.code, "fan-response-failed")
        XCTAssertNil(controller.status().leaseID)
    }

    func testLeaseExpiryRestoresAutomatic() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        _ = try controller.acquire(intent: .maximum, ownerSessionID: UUID(), leaseSeconds: 5)
        XCTAssertEqual(controller.status().mode, .maximum)

        clock.now += 6_000_000_000
        controller.tickNow()

        XCTAssertEqual(controller.status().mode, .automatic)
        XCTAssertNil(controller.status().leaseID)
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode.isAutomatic })
    }

    func testConnectionCloseReleasesItsLease() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        let session = UUID()
        _ = try controller.acquire(intent: .maximum, ownerSessionID: session, leaseSeconds: 20)

        controller.connectionClosed(session)
        let status = controller.status() // queue barrier after connectionClosed

        XCTAssertEqual(status.mode, .automatic)
        XCTAssertNil(status.leaseID)
    }

    func testWrongConnectionCannotRenewLease() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        let status = try controller.acquire(intent: .maximum, ownerSessionID: UUID(), leaseSeconds: 20)

        XCTAssertThrowsError(
            try controller.renew(leaseID: try XCTUnwrap(status.leaseID), ownerSessionID: UUID())
        ) { error in
            XCTAssertEqual(error as? DomainError, .leaseNotOwned)
        }
    }

    func testAnotherConnectionCannotReplaceAnActiveLease() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        let first = try controller.acquire(
            intent: .fixedRPM(2_000),
            ownerSessionID: UUID(),
            leaseSeconds: 20
        )

        XCTAssertThrowsError(
            try controller.acquire(intent: .maximum, ownerSessionID: UUID(), leaseSeconds: 20)
        ) { error in
            XCTAssertEqual(error as? DomainError, .controlOwnedByAnotherSession)
        }
        XCTAssertEqual(controller.status().leaseID, first.leaseID)
        XCTAssertEqual(controller.status().intent, .fixedRPM(2_000))
    }

    func testWakeRevokesLeaseAndReestablishesAutomatic() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        _ = try controller.acquire(intent: .maximum, ownerSessionID: UUID(), leaseSeconds: 20)

        controller.handleWake()
        let status = controller.status() // queue barrier after handleWake

        XCTAssertEqual(status.mode, .failSafeAutomatic)
        XCTAssertEqual(status.intent, .automatic)
        XCTAssertNil(status.leaseID)
        XCTAssertTrue(hardware.currentFans.allSatisfy { $0.mode.isAutomatic })
    }

    func testSamplingFailureRevokesLeaseAndNeverClaimsControl() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)
        controller.tickNow()
        _ = try controller.acquire(intent: .maximum, ownerSessionID: UUID(), leaseSeconds: 20)
        hardware.failSample = true

        controller.tickNow()

        XCTAssertEqual(controller.status().mode, .unrecoveredFault)
        XCTAssertEqual(controller.status().intent, .automatic)
        XCTAssertNil(controller.status().leaseID)
    }

    private func makeController(
        _ hardware: MockHardware,
        healthySamplesBeforeResume: Int = 0,
        thermalRecoveryRampRPMPerSecond: Double = 1_000
    ) -> (SafetyController, TestClock) {
        let clock = TestClock()
        let controller = SafetyController(
            hardware: hardware,
            configuration: SafetyConfiguration(
                tickIntervalSeconds: 0.25,
                sensorStaleSeconds: 2,
                maximumLeaseSeconds: 30,
                healthySamplesBeforeResume: healthySamplesBeforeResume,
                thermalRecoveryRampRPMPerSecond: thermalRecoveryRampRPMPerSecond,
                targetToleranceRPM: 100
            ),
            clock: { clock.now }
        )
        return (controller, clock)
    }
}

private final class TestClock: @unchecked Sendable {
    var now: UInt64 = 1_000_000_000
}

private final class MockHardware: ThermalHardware, @unchecked Sendable {
    let inventory: HardwareInventory
    var currentFans: [FanReading]
    var temperatures: [String: Double] = ["TC0P": 55, "TG0P": 50, "TH0A": 45]
    var failSample = false
    var failManual = false
    var failAutomatic = false
    var failMaximum = false
    var lieAboutManualReadback = false
    var lieAboutActualReadback = false
    var restoreCount = 0
    var maximumCount = 0
    var manualCount = 0

    init() throws {
        let fans = [
            try FanLimits(index: 0, minimumRPM: 1_200, maximumRPM: 6_000),
            try FanLimits(index: 1, minimumRPM: 1_400, maximumRPM: 5_500),
        ]
        let sensors = [
            try SensorDescriptor(key: "TC0P", family: .cpu, safetyLimitCelsius: 95),
            try SensorDescriptor(key: "TG0P", family: .gpu, safetyLimitCelsius: 95),
            try SensorDescriptor(key: "TH0A", family: .storage, safetyLimitCelsius: 80),
        ]
        inventory = try HardwareInventory(fans: fans, sensors: sensors)
        currentFans = fans.map {
            FanReading(index: $0.index, actualRPM: 0, targetRPM: 0, mode: .automatic)
        }
    }

    func sample() throws -> HardwareSample {
        if failSample { throw DomainError.hardwareFailure("injected sample failure") }
        let failures = inventory.sensors.map(\.key).filter { temperatures[$0] == nil }
        return try HardwareSample(fans: currentFans, temperatures: temperatures, failedSensorKeys: failures)
    }

    func applyManual(targetRPMs: [Int]) throws -> HardwareSample {
        manualCount += 1
        if failManual { throw DomainError.hardwareFailure("injected manual failure") }
        currentFans = zip(inventory.fans, targetRPMs).map { limits, target in
            FanReading(
                index: limits.index,
                actualRPM: lieAboutActualReadback ? 0 : target,
                targetRPM: target,
                mode: lieAboutManualReadback ? .automatic : .manual
            )
        }
        return try sample()
    }

    func restoreAutomatic() throws -> HardwareSample {
        restoreCount += 1
        if failAutomatic { throw DomainError.hardwareFailure("injected automatic failure") }
        currentFans = inventory.fans.map {
            FanReading(index: $0.index, actualRPM: 0, targetRPM: 0, mode: .automatic)
        }
        return try sample()
    }

    func applyMaximum() throws -> HardwareSample {
        maximumCount += 1
        if failMaximum { throw DomainError.hardwareFailure("injected maximum failure") }
        currentFans = inventory.fans.map {
            FanReading(index: $0.index, actualRPM: $0.maximumRPM, targetRPM: $0.maximumRPM, mode: .manual)
        }
        return try sample()
    }
}
