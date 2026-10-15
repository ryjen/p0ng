import XCTest
import MultipeerConnectivity
import PongCore
@testable import p0ng

/// Unit-level lifecycle coverage; no MultipeerConnectivity or Apple accounts.
@MainActor
final class PongCoordinatorUnitTests: XCTestCase {
    final class FakeTransport: GameTransport {
        var connected = false
        var onPeersChanged: (@MainActor @Sendable ([NearbyPeer]) -> Void)?
        var onInvitation: (@MainActor @Sendable (String) -> Void)?
        var onInvitationExpired: (@MainActor @Sendable () -> Void)?
        var onConnected: (@MainActor @Sendable () -> Void)?
        var onDisconnected: (@MainActor @Sendable (String) -> Void)?
        var onPacket: (@MainActor @Sendable (MatchMessage) -> Void)?
        var onError: (@MainActor @Sendable (String) -> Void)?
        var onDiscoveryFailed: (@MainActor @Sendable (String) -> Void)?
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

    func testExpiredHostInvitationDismissesAlertAndAllowsNewRequest() {
        let network = FakeTransport()
        let model = PongViewModel(transport: network)
        model.host()
        network.onInvitation?("visitor-1")
        XCTAssertEqual(model.invitation, "visitor-1")
        network.onInvitationExpired?()
        XCTAssertNil(model.invitation)
        XCTAssertNotNil(model.message)
        network.onInvitation?("visitor-2")
        XCTAssertEqual(model.invitation, "visitor-2")
        XCTAssertNil(model.message, "New invitation must clear stale expiry alert")
        model.respondToInvitation(true)
        XCTAssertNil(model.invitation)
        XCTAssertEqual(network.decisions, [true])
        // Delayed expiry from the old offer cannot clear a resolved request.
        network.onInvitationExpired?()
        XCTAssertNil(model.message)
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

    func testStaleDiscoveryAndSessionCallbacksDoNotReopenMenu() {
        let network = FakeTransport()
        let model = PongViewModel(transport: network)
        model.host()
        model.leave()

        let oldPeer = NearbyPeer(id: UUID(), displayName: "old-host")
        network.onPeersChanged?([oldPeer])
        network.onInvitation?("obsolete-request")
        network.onError?("stale network send")
        network.onDisconnected?("stale disconnection")
        network.connected = true
        network.onConnected?()

        XCTAssertEqual(model.screen, .menu)
        XCTAssertTrue(model.peers.isEmpty)
        XCTAssertNil(model.invitation)
        XCTAssertNil(model.message)
        XCTAssertFalse(model.isDisplayClockRunning)
    }

    func testDelayedOldSessionCallbacksCannotCancelSoloGame() {
        let network = FakeTransport()
        let model = PongViewModel(transport: network)
        model.host()
        model.leave()
        model.playSolo()
        let initial = model.state
        network.connected = true
        network.onConnected?()
        network.onDisconnected?("obsolete disconnect")
        network.onInvitation?("obsolete invite")
        network.onPacket?(MatchMessage(kind: .snapshot, matchID: UUID(),
                                      sequence: 42, state: PongSnapshot()))
        XCTAssertEqual(model.screen, .playing)
        XCTAssertEqual(model.roleLabel, "Solo · Left paddle")
        XCTAssertEqual(model.state, initial)
        XCTAssertNil(model.message)
        XCTAssertNil(model.invitation)
        XCTAssertTrue(model.isDisplayClockRunning)
    }

    func testGuestConnectionFailureBeforeHandshakeReturnsToRetryableMenu() {
        let network = FakeTransport()
        let model = PongViewModel(transport: network)
        model.browse()
        let peer = NearbyPeer(id: UUID(), displayName: "host")
        network.onPeersChanged?([peer])
        model.join(peer)
        XCTAssertEqual(model.screen, .connecting)
        network.onDisconnected?("Host unavailable or declined. Browse to retry.")
        XCTAssertEqual(model.screen, .menu)
        XCTAssertFalse(model.isReady)
        XCTAssertFalse(model.isDisplayClockRunning)
        XCTAssertTrue(model.peers.isEmpty)
        XCTAssertEqual(model.message, "Host unavailable or declined. Browse to retry.")
        XCTAssertGreaterThan(network.stops, 0)
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

extension PongCoordinatorUnitTests {
    func testInactiveScenePausesAndResumeAvoidsSimulationBurst() {
        let network = FakeTransport()
        let model = PongViewModel(transport: network)
        model.playSolo()
        XCTAssertTrue(model.isDisplayClockRunning)
        model.setInteractive(false)
        XCTAssertFalse(model.isDisplayClockRunning)
        XCTAssertEqual(model.screen, .playing, "Short interruption must not silently end a match")
        model.setInteractive(true)
        XCTAssertTrue(model.isDisplayClockRunning)
        model.leave()
        XCTAssertFalse(model.isDisplayClockRunning)
        model.setInteractive(false)
        model.setInteractive(true)
        XCTAssertFalse(model.isDisplayClockRunning)
    }

    func testLegacySoundResourcesArePackagedIntoModernApp() {
        XCTAssertNotNil(Bundle.main.url(forResource: "offthepaddle", withExtension: "wav"))
        XCTAssertNotNil(Bundle.main.url(forResource: "offthewall", withExtension: "wav"))
    }
}

/// Exercises the actual ObjC-delegate crossing guards using adversarial,
/// concurrent invocations without requiring Bluetooth/Wi-Fi or Apple accounts.
extension PongCoordinatorUnitTests {
    final class CallbackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testInvitationReplyFiresExactlyOnceWithConcurrentResolutions() {
        let recorder = CallbackRecorder()
        let reply = InvitationReply { _, _ in recorder.record() }
        DispatchQueue.concurrentPerform(iterations: 48) { _ in
            reply.respond(true, session: nil)
        }
        reply.respond(false, session: nil)
        XCTAssertEqual(recorder.count, 1)
    }

    // Legacy SDK objects are created before concurrent execution; the
    // transport ingress lock performs all subsequent identity comparisons.
    private struct TestNetworkReferences: @unchecked Sendable {
        let session: MCSession
        let peer: MCPeerID
        let unexpected: MCPeerID
    }

    func testDelegatePacketBudgetIsRaceFreeAndResetsPerSession() {
        let limiter = LockedPacketIngress()
        let accepted = CallbackRecorder()
        let references = TestNetworkReferences(
            session: MCSession(peer: MCPeerID(displayName: "local"),
                               securityIdentity: nil, encryptionPreference: .required),
            peer: MCPeerID(displayName: "authorized"),
            unexpected: MCPeerID(displayName: "untrusted"))

        XCTAssertFalse(limiter.allow(session: references.session,
                                     from: references.peer, at: 100))
        limiter.authorize(session: references.session, peer: references.peer)
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            let sender = index.isMultiple(of: 2) ? references.peer : references.unexpected
            if limiter.allow(session: references.session, from: sender, at: 100) {
                accepted.record()
            }
        }
        XCTAssertEqual(accepted.count, 120)
        XCTAssertFalse(limiter.allow(session: references.session,
                                     from: references.unexpected, at: 101))
        limiter.reset()
        XCTAssertFalse(limiter.allow(session: references.session,
                                     from: references.peer, at: 102))
        limiter.authorize(session: references.session, peer: references.unexpected)
        XCTAssertFalse(limiter.allow(session: references.session,
                                     from: references.peer, at: 103))
        XCTAssertTrue(limiter.allow(session: references.session,
                                    from: references.unexpected, at: 103))

        // A newer match may reuse its own peer label; the actual session
        // identity is part of admission, not just the display name.
        let otherSession = MCSession(peer: MCPeerID(displayName: "other-local"),
                                     securityIdentity: nil, encryptionPreference: .required)
        XCTAssertFalse(limiter.allow(session: otherSession,
                                     from: references.unexpected, at: 104))
        limiter.reset()
    }
}
