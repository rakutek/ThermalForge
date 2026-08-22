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

    func testBuiltInProfilesUseResponsiveDebounceAndRamps() throws {
        for profile in ProfileID.allCases {
            let curve = try profile.curve
            XCTAssertLessThanOrEqual(curve.sustainedSeconds, 3)
            XCTAssertGreaterThanOrEqual(curve.rampUpRPMPerSecond, 1_000)
            XCTAssertGreaterThanOrEqual(curve.rampDownRPMPerSecond, 500)
        }
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
