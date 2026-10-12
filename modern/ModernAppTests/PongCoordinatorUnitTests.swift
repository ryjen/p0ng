import XCTest
import PongCore
@testable import p0ng

/// Unit-level lifecycle coverage; no MultipeerConnectivity or Apple accounts.
@MainActor
final class PongCoordinatorUnitTests: XCTestCase {
    final class FakeTransport: GameTransport {
        var connected = false
        var onPeersChanged: (([NearbyPeer]) -> Void)?
        var onInvitation: ((String) -> Void)?
        var onConnected: (() -> Void)?
        var onDisconnected: ((String) -> Void)?
        var onPacket: ((MatchMessage) -> Void)?
        var onError: ((String) -> Void)?
        var onDiscoveryFailed: ((String) -> Void)?
        var messages: [OutgoingMessage] = []
        var decisions: [Bool] = []
        var hostCalls = 0
        var browseCalls = 0
        var stops = 0
        func host() { hostCalls += 1 }
        func browse() { browseCalls += 1 }
        func join(_ peer: NearbyPeer) {}
        func decideInvitation(accept: Bool) { decisions.append(accept) }
        func send(_ message: OutgoingMessage) { messages.append(message) }
        func stop() { stops += 1; connected = false }
    }

    func testHostInvitationAndDisconnectResetState() {
        let network = FakeTransport()
        let model = PongViewModel(transport: network)
        XCTAssertFalse(model.isDisplayClockRunning)
        model.host()
        XCTAssertEqual(network.hostCalls, 1)
        XCTAssertFalse(model.isDisplayClockRunning, "Advertising does not need 60 fps")
        network.onInvitation?("guest-1")
        XCTAssertEqual(model.invitation, "guest-1")
        model.respondToInvitation(true)
        model.respondToInvitation(true)
        XCTAssertEqual(network.decisions, [true], "Approval is idempotent")
        network.connected = true
        network.onConnected?()
        XCTAssertTrue(model.isDisplayClockRunning, "Handshake retries need a clock")

        var guest = MatchCoordinator()
        guest.startJoining()
        network.onPacket?(guest.handshakeRetry()!.packet)
        let welcome = try! XCTUnwrap(network.messages.last).packet
        let ready = guest.acceptHandshake(welcome).response!.packet
        network.onPacket?(ready)
        let start = network.messages.last!.packet
        let started = guest.acceptHandshake(start).response!.packet
        network.onPacket?(started)
        XCTAssertEqual(model.screen, .playing)
        XCTAssertTrue(model.isDisplayClockRunning)

        network.onDisconnected?("Connection lost")
        XCTAssertEqual(model.screen, .menu)
        XCTAssertFalse(model.isDisplayClockRunning)
        XCTAssertEqual(model.message, "Connection lost")
        XCTAssertFalse(model.isReady)
    }

    func testCancelledDiscoveryCanRetryWithoutReusingSession() {
        let network = FakeTransport()
        let model = PongViewModel(transport: network)
        model.host()
        network.onDiscoveryFailed?("Local Network denied")
        XCTAssertEqual(model.screen, .menu)
        XCTAssertTrue(model.canRetryDiscovery)
        XCTAssertFalse(model.isDisplayClockRunning)
        model.retryDiscovery()
        XCTAssertEqual(network.hostCalls, 2)
        XCTAssertFalse(model.canRetryDiscovery)
    }

    func testBrowsingUsesTransportNeutralPeerIDs() {
        let network = FakeTransport()
        let model = PongViewModel(transport: network)
        model.browse()
        let peer = NearbyPeer(id: UUID(), displayName: "test-peer")
        network.onPeersChanged?([peer])
        XCTAssertEqual(model.peers, [peer])
        XCTAssertEqual(model.screen, .browsing)
        XCTAssertFalse(model.isDisplayClockRunning)
        model.leave()
        XCTAssertEqual(model.screen, .menu)
        XCTAssertTrue(model.peers.isEmpty,
                      "Leaving must clear stale discovered peers even if transport callback is absent")
    }

    func testLatePacketAfterLeaveCannotRestorePlayingScreen() {
        let network = FakeTransport()
        let model = PongViewModel(transport: network)
        model.host()
        model.leave()
        let packet = MatchMessage(kind: .started, matchID: UUID(), sequence: 0)
        network.onPacket?(packet)
        XCTAssertEqual(model.screen, .menu)
        XCTAssertFalse(model.isReady)
    }
}
