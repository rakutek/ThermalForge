import XCTest
@testable import KazeDomain

final class ProfileTests: XCTestCase {
    func testBuiltInCurvesSatisfySafetyInvariants() throws {
        for profile in ProfileID.allCases {
            let curve = try profile.curve
            XCTAssertTrue(curve.stopTemperature < curve.startTemperature)
            XCTAssertTrue(curve.startTemperature < curve.ceilingTemperature)
            XCTAssertLessThanOrEqual(curve.ceilingTemperature, 95)
            XCTAssertTrue(curve.maximumFraction.isFinite)
            XCTAssertTrue((0...1).contains(curve.maximumFraction))
        }
    }

    /// Perceived fan noise tracks how fast the speed *changes*, not the speed itself, so
    /// every profile ramps gradually in both directions. The lower bounds keep a profile
    /// from lagging so far behind its curve that it never reaches the target, and ramping
    /// down no faster than up is what stops the fans from hunting around a threshold.
    func testBuiltInProfilesRampGraduallyInBothDirections() throws {
        for profile in ProfileID.allCases {
            let curve = try profile.curve
            XCTAssertLessThanOrEqual(curve.sustainedSeconds, 3)
            XCTAssertTrue(
                (50...600).contains(curve.rampUpRPMPerSecond),
                "\(profile.rawValue) ramps up at \(curve.rampUpRPMPerSecond) RPM/s"
            )
            XCTAssertTrue(
                (50...300).contains(curve.rampDownRPMPerSecond),
                "\(profile.rawValue) ramps down at \(curve.rampDownRPMPerSecond) RPM/s"
            )
            XCTAssertLessThanOrEqual(curve.rampDownRPMPerSecond, curve.rampUpRPMPerSecond)
        }
    }

    func testSmartProfileHasGentlerRiseAndLowerTopSpeedThanPerformance() throws {
        let smart = try ProfileID.smart.curve
        let performance = try ProfileID.performance.curve

        XCTAssertEqual(smart.rampUpRPMPerSecond, 50)
        XCTAssertEqual(smart.rampDownRPMPerSecond, 50)
        XCTAssertEqual(smart.maximumFraction, 0.80)
        XCTAssertLessThan(smart.rampUpRPMPerSecond, performance.rampUpRPMPerSecond)
        XCTAssertLessThan(smart.maximumFraction, performance.maximumFraction)
    }

    func testCurveIsMonotonicAndBounded() throws {
        for profile in ProfileID.allCases {
            let curve = try profile.curve
            var previous = 0.0
            for temperature in stride(from: 0.0, through: 120.0, by: 0.25) {
                let value = curve.fraction(at: temperature)
                XCTAssertGreaterThanOrEqual(value, previous)
                XCTAssertLessThanOrEqual(value, curve.maximumFraction)
                previous = value
            }
        }
    }

    func testNonFiniteProfileValueIsRejected() {
        XCTAssertThrowsError(
            try ProfileCurve(
                stopTemperature: 50,
                startTemperature: .nan,
                ceilingTemperature: 80,
                maximumFraction: 1,
                shape: .linear,
                sustainedSeconds: 2,
                rampUpRPMPerSecond: 500,
                rampDownRPMPerSecond: 250
            )
        )
    }
}
