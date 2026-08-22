import XCTest
@testable import KazeIPC

final class CodecTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let request = HelperRequest(operation: .acquire(intent: .fixedRPM(3_000), leaseSeconds: 20))
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
}
