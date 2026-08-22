import XCTest
@testable import KazeHardware

final class EncodingTests: XCTestCase {
    func testSMCFloatRoundTrip() throws {
        for value in [0.0, 1_200.0, 6_000.0] {
            XCTAssertEqual(try decodeSMCFloat(encodeSMCFloat(value)), value, accuracy: 0.01)
        }
    }

    func testNonFiniteSMCFloatIsRejected() {
        XCTAssertThrowsError(try encodeSMCFloat(.nan))
        XCTAssertThrowsError(try encodeSMCFloat(.infinity))
    }

    func testSMCKeysMustBeExactlyFourPrintableBytes() throws {
        XCTAssertNoThrow(try fourCharacterCode("F0Tg"))
        XCTAssertThrowsError(try fourCharacterCode("F-1Tg"))
        XCTAssertThrowsError(try fourCharacterCode("F10Tg"))
        XCTAssertThrowsError(try fourCharacterCode("abc\n"))
    }

    func testIOFixedTemperatureDecode() throws {
        XCTAssertEqual(try decodeIOFixedTemperature([0x00, 0x80, 0x37, 0x00]), 55.5, accuracy: 0.001)
    }

    func testManualModeIsRetriedUntilReadbackLatches() throws {
        let transport = DelayedManualModeTransport()
        let hardware = try SMCFanHardware(transport: transport)

        let sample = try hardware.applyMaximum()

        XCTAssertGreaterThanOrEqual(transport.manualWriteAttempts, 3)
        XCTAssertGreaterThanOrEqual(transport.targetWriteAttempts, 3)
        XCTAssertEqual(sample.fans.first?.mode, .manual)
        XCTAssertEqual(sample.fans.first?.targetRPM, 6_000)

        let restored = try hardware.restoreAutomatic()
        XCTAssertGreaterThanOrEqual(transport.automaticWriteAttempts, 3)
        XCTAssertEqual(restored.fans.first?.mode, .automatic)
    }
}

private final class DelayedManualModeTransport: SMCTransport {
    private enum TestError: Error { case missingKey(String) }

    private var values: [String: [UInt8]] = [
        "FNum": [1],
        "F0Md": [0],
        "Ftst": [0],
        "F0Mn": try! encodeSMCFloat(2_000),
        "F0Mx": try! encodeSMCFloat(6_000),
        "F0Ac": try! encodeSMCFloat(2_500),
        "F0Tg": try! encodeSMCFloat(2_500),
        "TCDX": try! encodeSMCFloat(50),
    ]

    private(set) var manualWriteAttempts = 0
    private(set) var automaticWriteAttempts = 0
    private(set) var targetWriteAttempts = 0

    func read(_ key: String) throws -> SMCValue {
        guard let bytes = values[key] else { throw TestError.missingKey(key) }
        return SMCValue(type: "test", bytes: bytes)
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        guard values[key] != nil else { throw TestError.missingKey(key) }
        if key == "F0Md" {
            if bytes == [1] {
                manualWriteAttempts += 1
                if values["Ftst"] == [1], manualWriteAttempts >= 3 {
                    values[key] = [1]
                }
            } else {
                automaticWriteAttempts += 1
                if values["Ftst"] == [0], automaticWriteAttempts >= 3 {
                    values[key] = [0]
                }
            }
            return
        }
        if key == "F0Tg", let maximum = try? encodeSMCFloat(6_000), bytes == maximum {
            targetWriteAttempts += 1
            if targetWriteAttempts >= 3 { values[key] = bytes }
            return
        }
        values[key] = bytes
    }
}
