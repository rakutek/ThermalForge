import XCTest
@testable import KazeDomain

final class SafetyControllerTests: XCTestCase {
    func testDefaultThermalRecoveryWaitsAndRampsDownConservatively() {
        let configuration = SafetyConfiguration()

        XCTAssertEqual(configuration.healthySamplesBeforeResume, 40)
        XCTAssertEqual(configuration.thermalRecoveryRampRPMPerSecond, 100)
    }

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
        let session = UUID()
        let acquired = try controller.acquire(
            intent: .profile(.smart),
            ownerSessionID: session,
            leaseSeconds: 30
        )
        let leaseID = try XCTUnwrap(acquired.leaseID)

        // Settle: the profile debounces for sustainedSeconds before taking manual control,
        // then the ramp limiter walks up to the curve target at 50 RPM/s. Only measure
        // once it has had enough time to get there from the idle floor.
        for index in 0..<160 {
            clock.now += 250_000_000
            if index.isMultiple(of: 40) {
                _ = try controller.renew(leaseID: leaseID, ownerSessionID: session)
            }
            hardware.temperatures["TC0P"] = index.isMultiple(of: 2) ? 68 : 71
            controller.tickNow()
        }

        let writesBeforeObservation = hardware.manualCount
        var observed: [Int] = []
        for index in 0..<24 {
            clock.now += 250_000_000
            _ = try controller.renew(leaseID: leaseID, ownerSessionID: session)
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

    func testSmartDoesNotChaseSingleSafeTemperatureSpike() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        hardware.temperatures["TC0P"] = 60
        controller.tickNow()
        _ = try controller.acquire(
            intent: .profile(.smart),
            ownerSessionID: UUID(),
            leaseSeconds: 30
        )

        for _ in 0..<9 {
            clock.now += 250_000_000
            controller.tickNow()
        }
        let settled = hardware.currentFans[0].targetRPM

        // A one-sample peak below the 95°C safety limit must pass through the
        // temperature filter instead of jumping directly to the 3,000 RPM boundary.
        hardware.temperatures["TC0P"] = 94
        clock.now += 250_000_000
        controller.tickNow()

        let afterSpike = hardware.currentFans[0].targetRPM
        XCTAssertEqual(controller.status().mode, .smart)
        XCTAssertLessThan(afterSpike, 3_000)
        XCTAssertLessThanOrEqual(afterSpike, settled + 300)
    }

    func testSmartProfileStillRampsUpOnSustainedTemperatureRise() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        hardware.temperatures["TC0P"] = 60
        controller.tickNow()
        let session = UUID()
        let acquired = try controller.acquire(
            intent: .profile(.smart),
            ownerSessionID: session,
            leaseSeconds: 30
        )
        let leaseID = try XCTUnwrap(acquired.leaseID)

        for index in 0..<40 {
            clock.now += 250_000_000
            if index.isMultiple(of: 20) {
                _ = try controller.renew(leaseID: leaseID, ownerSessionID: session)
            }
            controller.tickNow()
        }
        let settled = hardware.currentFans[0].targetRPM

        // Forty seconds of rising die temperature, held short of the sensor's 95 degree
        // safety limit so this exercises the profile rather than the thermal override.
        // Smart ramps at 50 RPM/s, so the window has to be long enough for the limiter
        // to actually deliver a meaningful climb.
        for index in 0..<160 {
            clock.now += 250_000_000
            if index.isMultiple(of: 40) {
                _ = try controller.renew(leaseID: leaseID, ownerSessionID: session)
            }
            hardware.temperatures["TC0P"] = min(60 + Double(index + 1), 88)
            controller.tickNow()
        }

        XCTAssertEqual(controller.status().mode, .smart)
        XCTAssertGreaterThan(hardware.currentFans[0].targetRPM, settled + 1_500)
    }

    func testSmartRiseBoostNeverExceedsProfileTopSpeed() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        hardware.temperatures["TC0P"] = 84
        controller.tickNow()
        let session = UUID()
        let acquired = try controller.acquire(
            intent: .profile(.smart),
            ownerSessionID: session,
            leaseSeconds: 30
        )
        let leaseID = try XCTUnwrap(acquired.leaseID)

        // Settle just below the curve ceiling, then create a sharp but still safe rise.
        // This activates Smart's anticipatory boost while the base curve is already at
        // its configured top speed.
        for index in 0..<340 {
            clock.now += 250_000_000
            if index.isMultiple(of: 40) {
                _ = try controller.renew(leaseID: leaseID, ownerSessionID: session)
            }
            controller.tickNow()
        }

        hardware.temperatures["TC0P"] = 94
        var observedTargets: [Int] = []
        for _ in 0..<12 {
            clock.now += 250_000_000
            _ = try controller.renew(leaseID: leaseID, ownerSessionID: session)
            controller.tickNow()
            observedTargets.append(hardware.currentFans[0].targetRPM)
        }

        let limits = hardware.inventory.fans[0]
        let smart = try ProfileID.smart.curve
        let topSpeed = limits.minimumRPM
            + Int((Double(limits.maximumRPM - limits.minimumRPM) * smart.maximumFraction).rounded())

        XCTAssertEqual(controller.status().mode, .smart)
        XCTAssertLessThanOrEqual(observedTargets.max() ?? 0, topSpeed)
    }

    func testSmartMovesImmediatelyBelowThreeThousandAndRampsAboveIt() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        hardware.temperatures["TC0P"] = 60
        controller.tickNow()
        _ = try controller.acquire(
            intent: .profile(.smart),
            ownerSessionID: UUID(),
            leaseSeconds: 30
        )

        // Once the profile debounce completes, a target in the quiet range lands
        // immediately instead of walking up from the hardware floor.
        for _ in 0..<9 {
            clock.now += 250_000_000
            controller.tickNow()
        }
        let quietTarget = hardware.currentFans[0].targetRPM
        XCTAssertEqual(hardware.currentFans[0].mode, .manual)
        XCTAssertGreaterThan(quietTarget, hardware.inventory.fans[0].minimumRPM)
        XCTAssertLessThan(quietTarget, 3_000)

        // A sharp temperature rise may jump to the 3,000 RPM boundary, but only one
        // tick's ramp allowance may be added above it.
        hardware.temperatures["TC0P"] = 90
        clock.now += 250_000_000
        controller.tickNow()

        let firstLoudTarget = hardware.currentFans[0].targetRPM
        let permittedAboveBoundary = Int((try ProfileID.smart.curve.rampUpRPMPerSecond * 0.25).rounded(.up))
        XCTAssertLessThan(quietTarget, firstLoudTarget)
        XCTAssertLessThanOrEqual(firstLoudTarget, 3_000 + permittedAboveBoundary)
    }

    /// Audible fan noise is dominated by how abruptly the speed changes, so no profile may
    /// hand the SMC a large step in one write. The bound is the ramp allowance for one tick
    /// plus the write tolerance, since a sub-tolerance move is held back and applied later.
    func testProfilesNeverStepFanSpeedAbruptly() throws {
        for profile in ProfileID.allCases {
            let hardware = try MockHardware()
            let (controller, clock) = makeController(hardware)
            controller.start(startTimer: false)
            hardware.temperatures["TC0P"] = 60
            controller.tickNow()
            _ = try controller.acquire(intent: .profile(profile), ownerSessionID: UUID(), leaseSeconds: 30)

            let curve = try profile.curve
            let permitted = 100 + Int((curve.rampUpRPMPerSecond * 0.25).rounded())
            var previous: Int?
            var largestRateLimitedStep = 0

            // Slam the die temperature between idle and near-ceiling every 20 ticks. Both
            // ends stay above the profile's stop temperature, so control never hands back
            // to the SMC and every move here is the ramp limiter's own work. Ticks where
            // the fan is not already under manual control are skipped: the first manual
            // write starts from whatever the SMC last targeted, which the mock reports as
            // zero, and that handoff is not what the ramp limiter governs.
            for index in 0..<80 {
                clock.now += 250_000_000
                hardware.temperatures["TC0P"] = (index / 20).isMultiple(of: 2) ? 60 : 90
                controller.tickNow()
                let fan = hardware.currentFans[0]
                guard fan.mode == .manual else {
                    previous = nil
                    continue
                }
                if let previous {
                    let lower = min(previous, fan.targetRPM)
                    let upper = max(previous, fan.targetRPM)
                    let entersSmartRamp = profile == .smart
                        && lower <= 3_000
                        && upper <= 3_000 + Int((curve.rampUpRPMPerSecond * 0.25).rounded(.up))
                    if !entersSmartRamp {
                        largestRateLimitedStep = max(
                            largestRateLimitedStep,
                            abs(fan.targetRPM - previous)
                        )
                    }
                }
                previous = fan.targetRPM
            }

            XCTAssertGreaterThan(
                largestRateLimitedStep, 0,
                "\(profile.rawValue) never moved fan 0 in its rate-limited range"
            )
            XCTAssertLessThanOrEqual(
                largestRateLimitedStep, permitted,
                "\(profile.rawValue) stepped fan 0 by \(largestRateLimitedStep) RPM in one tick"
            )
        }
    }

    /// Releasing a spinning fan back to the SMC in one tick is the sharpest change the
    /// profile path can produce, and no ramp rate can soften it. Once the die cools past
    /// the stop temperature the profile keeps control and walks the fan down to its floor,
    /// handing back only when there is nothing left to hear.
    func testProfileWindsDownToTheFanFloorBeforeReleasingControl() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)
        hardware.temperatures["TC0P"] = 80
        controller.tickNow()
        let session = UUID()
        let acquired = try controller.acquire(
            intent: .profile(.smart),
            ownerSessionID: session,
            leaseSeconds: 30
        )
        let leaseID = try XCTUnwrap(acquired.leaseID)

        // Climb well clear of the fan floor.
        for index in 0..<180 {
            clock.now += 250_000_000
            if index.isMultiple(of: 40) {
                _ = try controller.renew(leaseID: leaseID, ownerSessionID: session)
            }
            controller.tickNow()
        }
        let hot = hardware.currentFans[0].targetRPM
        XCTAssertGreaterThan(hot, 3_000, "profile never spun the fan up")

        // Go idle abruptly. Both die sensors have to cool: the profile reads their peak,
        // and it deliberately keeps control while either sits in the stop/start band.
        // The app renews its lease throughout, as it does in normal use.
        hardware.temperatures["TC0P"] = 30
        hardware.temperatures["TG0P"] = 30
        var releasedFrom: Int?
        var previous = hot
        var largestRateLimitedDrop = 0
        for _ in 0..<400 where releasedFrom == nil {
            clock.now += 250_000_000
            _ = try controller.renew(leaseID: leaseID, ownerSessionID: session)
            controller.tickNow()
            let fan = hardware.currentFans[0]
            guard fan.mode == .manual else {
                releasedFrom = previous
                continue
            }
            if previous > 3_000 {
                largestRateLimitedDrop = max(
                    largestRateLimitedDrop,
                    previous - fan.targetRPM
                )
            }
            previous = fan.targetRPM
        }

        let floor = hardware.inventory.fans[0].minimumRPM
        XCTAssertEqual(
            releasedFrom, floor,
            "control returned to the SMC at \(releasedFrom.map(String.init) ?? "never") RPM"
        )
        XCTAssertLessThanOrEqual(
            largestRateLimitedDrop,
            100 + Int((try ProfileID.smart.curve.rampDownRPMPerSecond * 0.25).rounded()),
            "wind-down dropped fan 0 by \(largestRateLimitedDrop) RPM in one tick"
        )
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

    func testTelemetryAggregatesSensorFamiliesAtOneSecondIntervals() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)

        hardware.temperatures["TC0P"] = 57
        hardware.temperatures["TG0P"] = 63
        clock.now += 500_000_000
        controller.tickNow()
        XCTAssertEqual(try controller.telemetry(windowSeconds: 60, maximumPoints: 60).count, 1)

        clock.now += 500_000_000
        controller.tickNow()

        let records = try controller.telemetry(windowSeconds: 60, maximumPoints: 60)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.last?.peakTemperatures[.cpu], 57)
        XCTAssertEqual(records.last?.peakTemperatures[.gpu], 63)
        XCTAssertEqual(records.last?.peakTemperatures[.storage], 45)
        XCTAssertEqual(records.last?.fanActualRPMs, [0, 0])
        XCTAssertEqual(records.last?.mode, .automatic)
    }

    func testTelemetryDownsamplingRetainsThermalSpikeAndBoundsResult() throws {
        let hardware = try MockHardware()
        let (controller, clock) = makeController(hardware)
        controller.start(startTimer: false)

        for index in 0..<300 {
            hardware.temperatures["TC0P"] = index == 151 ? 99 : 55
            clock.now += 1_000_000_000
            controller.tickNow()
        }

        let records = try controller.telemetry(windowSeconds: 3_600, maximumPoints: 20)
        XCTAssertEqual(records.count, 20)
        XCTAssertEqual(records.first?.sampledAtUptimeNanoseconds, 1_000_000_000)
        XCTAssertEqual(records.last?.sampledAtUptimeNanoseconds, clock.now)
        XCTAssertTrue(records.contains { $0.peakTemperatures[.cpu] == 99 })
    }

    func testTelemetryRejectsUnboundedQueries() throws {
        let hardware = try MockHardware()
        let (controller, _) = makeController(hardware)
        controller.start(startTimer: false)

        XCTAssertThrowsError(try controller.telemetry(windowSeconds: .infinity, maximumPoints: 60))
        XCTAssertThrowsError(try controller.telemetry(windowSeconds: 3_601, maximumPoints: 60))
        XCTAssertThrowsError(
            try controller.telemetry(
                windowSeconds: 60,
                maximumPoints: SafetyController.maximumTelemetryPoints + 1
            )
        )
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
