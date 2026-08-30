import XCTest
@testable import KazeIPC
import KazeDomain

final class CodecTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let request = HelperRequest(operation: .acquire(intent: .fixedRPM(3_000), leaseSeconds: 20))
        XCTAssertEqual(try XPCCodec.decodeRequest(XPCCodec.encode(request)), request)
    }

    func testTelemetryRequestRoundTrip() throws {
        let request = HelperRequest(operation: .telemetry(windowSeconds: 900, maximumPoints: 180))
        XCTAssertEqual(try XPCCodec.decodeRequest(XPCCodec.encode(request)), request)
    }

    func testMalformedPayloadIsRejected() {
        XCTAssertThrowsError(try XPCCodec.decodeRequest(Data("not-json".utf8)))
    }

    func testOversizedPayloadIsRejectedBeforeDecode() {
        let data = Data(repeating: 0, count: XPCCodec.maximumPayloadBytes + 1)
        XCTAssertThrowsError(try XPCCodec.decodeRequest(data)) { error in
            XCTAssertEqual(error as? XPCCodecError, .payloadTooLarge(data.count))
        }
    }

    func testResponseMustMatchRequestID() throws {
        let request = HelperRequest(operation: .status)
        let error = HelperRPCError(code: "test", message: "test")
        let response = HelperResponse(requestID: UUID(), error: error)
        XCTAssertThrowsError(try XPCCodec.decodeResponse(XPCCodec.encode(response), for: request)) { thrown in
            XCTAssertEqual(thrown as? XPCCodecError, .responseMismatch)
        }
    }

    func testProtocolVersionMismatchIsRejected() throws {
        let request = HelperRequest(operation: .status)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XPCCodec.encode(request)) as? [String: Any]
        )
        object["protocolVersion"] = 999
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try XPCCodec.decodeRequest(data)) { error in
            XCTAssertEqual(error as? XPCCodecError, .protocolMismatch(received: 999))
        }
    }

    func testRecentRequestReplayIsRejected() {
        let window = RequestReplayWindow()
        let identifier = UUID()

        XCTAssertTrue(window.accept(identifier))
        XCTAssertFalse(window.accept(identifier))
    }

    func testTransportErrorsAreRecoverableConnectionFailures() {
        XCTAssertTrue(HelperClientError.unavailable("test").isConnectionFailure)
        XCTAssertTrue(HelperClientError.invalidProxy.isConnectionFailure)
        XCTAssertTrue(HelperClientError.timedOut(seconds: 1).isConnectionFailure)
    }

    func testProtocolAndRemoteErrorsDoNotDiscardAHealthyConnection() {
        XCTAssertFalse(HelperClientError.missingResult.isConnectionFailure)
        XCTAssertFalse(HelperClientError.missingTelemetry.isConnectionFailure)
        XCTAssertFalse(
            HelperClientError.remote(HelperRPCError(code: "test", message: "test"))
                .isConnectionFailure
        )
    }

    func testMaximumTelemetryResponseFitsBoundedPayload() throws {
        let families = SensorFamily.allCasesForTesting
        let fans = try (0..<8).map {
            try FanLimits(index: $0, minimumRPM: 1_000 + $0, maximumRPM: 8_000 + $0)
        }
        let sensors = try (0..<50).map { index in
            try SensorDescriptor(
                key: String(format: "T%03d", index),
                family: families[index % families.count],
                safetyLimitCelsius: 90
            )
        }
        let inventory = try HardwareInventory(fans: fans, sensors: sensors)
        let hardwareSample = try HardwareSample(
            fans: fans.map {
                FanReading(index: $0.index, actualRPM: 4_000, targetRPM: 4_500, mode: .manual)
            },
            temperatures: Dictionary(uniqueKeysWithValues: sensors.map { ($0.key, 72.5) })
        )
        let status = ControllerStatus(
            mode: .smart,
            intent: .profile(.smart),
            leaseID: UUID(),
            leaseExpiresAtUptimeNanoseconds: 99_000_000_000,
            inventory: inventory,
            latestSample: hardwareSample,
            fault: nil
        )
        let peaks = Dictionary(uniqueKeysWithValues: families.map { ($0, 72.5) })
        let telemetry = (0..<SafetyController.maximumTelemetryPoints).map { index in
            TelemetrySample(
                sampledAtUptimeNanoseconds: UInt64(index) * 1_000_000_000,
                mode: .smart,
                peakTemperatures: peaks,
                fanActualRPMs: Array(repeating: 4_000, count: 8),
                fanTargetRPMs: Array(repeating: 4_500, count: 8),
                faultCode: nil
            )
        }
        let request = HelperRequest(operation: .telemetry(windowSeconds: 3_600, maximumPoints: 180))
        let response = HelperResponse(
            requestID: request.requestID,
            result: HelperResult(status: status, telemetry: telemetry)
        )

        let data = try XPCCodec.encode(response)
        XCTAssertLessThanOrEqual(data.count, XPCCodec.maximumPayloadBytes)
        let decoded = try XPCCodec.decodeResponse(data, for: request)
        XCTAssertEqual(decoded.result?.telemetry?.count, SafetyController.maximumTelemetryPoints)
    }
}

private extension SensorFamily {
    static let allCasesForTesting: [SensorFamily] = [
        .cpu, .gpu, .memory, .storage, .power, .battery, .ambient, .other,
    ]
}
