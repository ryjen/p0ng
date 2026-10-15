import XCTest
@testable import PongCore

final class OutboundSendPolicyTests: XCTestCase {
    func testReliableControlFailsClosedWhenAConnectedPeerIsNotAuthorized() {
        XCTAssertEqual(OutboundSendPolicy.evaluate(
            connected: true, singleAuthorizedPeer: false, quality: .reliable),
            .terminate, "Never silently lose a score or start/phase transition")
        XCTAssertEqual(OutboundSendPolicy.evaluate(
            connected: true, singleAuthorizedPeer: false, quality: .realtime),
            .terminate, "Unexpected peer topology invalidates the session")
        XCTAssertEqual(OutboundSendPolicy.evaluate(
            connected: false, singleAuthorizedPeer: false, quality: .reliable),
            .ignore, "A later callback after teardown must not raise a second error")
    }

    func testPayloadLimitDoesNotDropReliableControlSilently() {
        for count in [0, 4097, Int.max] {
            XCTAssertEqual(OutboundSendPolicy.evaluate(
                connected: true, singleAuthorizedPeer: true,
                quality: .reliable, encodedByteCount: count), .terminate)
            XCTAssertEqual(OutboundSendPolicy.evaluate(
                connected: true, singleAuthorizedPeer: true,
                quality: .realtime, encodedByteCount: count), .ignore)
        }
        for quality in [SendQuality.reliable, .realtime] {
            XCTAssertEqual(OutboundSendPolicy.evaluate(
                connected: true, singleAuthorizedPeer: true,
                quality: quality, encodedByteCount: 4096), .transmit)
            XCTAssertEqual(OutboundSendPolicy.evaluate(
                connected: true, singleAuthorizedPeer: true,
                quality: quality), .transmit)
        }
    }
}
