import XCTest
import UIKit
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
        var onDiscoveryFailed: (@MainActor @Sendable (DiscoveryFailure) -> Void)?
        var messages: [OutgoingMessage] = []
        var decisions: [Bool] = []
        var hostCalls = 0
        var browseCalls = 0
        var joinResult: NearbyJoinResult = .invitationSent
        var joinCalls: [NearbyPeer] = []
        var stops = 0
        func host() { hostCalls += 1 }
        func browse() { browseCalls += 1 }
        func join(_ peer: NearbyPeer) -> NearbyJoinResult {
            joinCalls.append(peer)
            return joinResult
        }
        func decideInvitation(accept: Bool) { decisions.append(accept) }
        func send(_ message: OutgoingMessage) { messages.append(message) }
        func stop() { stops += 1; connected = false }
    }

    final class FakeFrameClock: FrameClock {
        var onFrame: (@MainActor (TimeInterval) -> Void)?
        var isRunning = false
        func setRunning(_ running: Bool) { isRunning = running }
    }

    final class ManualScheduler: DeadlineScheduling {
        struct Entry {
            let seconds: TimeInterval
            let action: @MainActor @Sendable () -> Void
        }
        private(set) var entries: [Entry] = []
        private(set) var cancelled: Set<Int> = []
        func schedule(after seconds: TimeInterval,
                      _ action: @escaping @MainActor @Sendable () -> Void) -> CancelDeadline {
            let index = entries.count
            entries.append(Entry(seconds: seconds, action: action))
            return { [weak self] in _ = self?.cancelled.insert(index) }
        }
        // Deliberately allow firing a cancelled entry to simulate a race.
        func fire(_ index: Int) { entries[index].action() }
    }

    final class FakeIdleTimer: IdleTimerControlling {
        var preventingSleep = false
        func setPreventingSleep(_ active: Bool) { preventingSleep = active }
    }

    final class FakeFeedback: GameFeedbacking {
        func reset() {}
        func observe(_ next: PongSnapshot) {}
    }

    private func makeModel(_ network: FakeTransport,
                           scheduler: ManualScheduler = ManualScheduler(),
                           idleTimer: FakeIdleTimer = FakeIdleTimer()) -> PongViewModel {
        PongViewModel(interactor: SessionInteractor(
            transport: network, clock: FakeFrameClock(), now: { 100 },
            scheduler: scheduler, feedback: FakeFeedback(), idleTimer: idleTimer))
    }

    func testHostHandshakeDeadlineIsBoundedAndOldTimerCannotEndReplacement() {
        let network = FakeTransport()
        let scheduler = ManualScheduler()
        let idle = FakeIdleTimer()
        let model = makeModel(network, scheduler: scheduler, idleTimer: idle)
        model.host()
        XCTAssertTrue(idle.preventingSleep)
        XCTAssertTrue(scheduler.entries.isEmpty, "Idle hosting has no timeout")
        network.connected = true
        network.onConnected?()
        XCTAssertEqual(scheduler.entries.last?.seconds, NearbySessionPolicy.handshakeDeadlineSeconds)
        scheduler.fire(0)
        XCTAssertEqual(model.screen, .menu)
        XCTAssertTrue(model.canRetryDiscovery)
        XCTAssertFalse(idle.preventingSleep)
        model.retryDiscovery()
        XCTAssertEqual(model.screen, .hosting)
        scheduler.fire(0)
        XCTAssertEqual(model.screen, .hosting)
        model.leave()
        XCTAssertFalse(idle.preventingSleep)
    }

    func testGuestTransportAndHandshakeHaveSeparateDeadlines() {
        let network = FakeTransport()
        let scheduler = ManualScheduler()
        let model = makeModel(network, scheduler: scheduler)
        model.browse()
        let peer = NearbyPeer(id: UUID(), displayName: "host")
        model.join(peer)
        XCTAssertEqual(scheduler.entries.last?.seconds, NearbySessionPolicy.guestConnectionDeadlineSeconds)
        network.connected = true
        network.onConnected?()
        XCTAssertTrue(scheduler.cancelled.contains(0))
        XCTAssertEqual(scheduler.entries.last?.seconds, NearbySessionPolicy.handshakeDeadlineSeconds)
        scheduler.fire(0)
        XCTAssertEqual(model.screen, .connecting)
        scheduler.fire(1)
        XCTAssertEqual(model.screen, .menu)
        XCTAssertTrue(model.canRetryDiscovery)
    }

    func testForegroundHostingRetainsSessionAndReleasesIdleTimer() {
        let network = FakeTransport()
        let idle = FakeIdleTimer()
        let model = makeModel(network, idleTimer: idle)
        model.host()
        XCTAssertTrue(idle.preventingSleep)
        model.setInteractive(false)
        XCTAssertFalse(idle.preventingSleep)
        XCTAssertEqual(model.screen, .hosting)
        model.setInteractive(true)
        XCTAssertTrue(idle.preventingSleep)
        network.onDiscoveryFailed?(DiscoveryFailure(operation: .preflight,
            domain: "DNSService", code: -65570, detail: "Policy denied"))
        XCTAssertEqual(model.screen, .menu)
        XCTAssertFalse(idle.preventingSleep)
        XCTAssertTrue(model.message?.contains("DNSService:-65570") == true)
        XCTAssertTrue(model.canRetryDiscovery)
    }

    func testNativeIdleTimerRestoresOriginalValue() {
        var disabled = false
        let idle = NativeIdleTimer(read: { disabled }, write: { disabled = $0 })
        idle.setPreventingSleep(true)
        XCTAssertTrue(disabled)
        idle.setPreventingSleep(true)
        idle.setPreventingSleep(false)
        XCTAssertFalse(disabled)
        disabled = true
        idle.setPreventingSleep(true)
        idle.setPreventingSleep(false)
        XCTAssertTrue(disabled)
    }

    final class FakeProbe: DiscoveryPreflighting {
        var completions: [@MainActor (Result<Void, DiscoveryFailure>) -> Void] = []
        private(set) var cancels = 0
        func start(completion: @escaping @MainActor (Result<Void, DiscoveryFailure>) -> Void) {
            completions.append(completion)
        }
        func cancel() { cancels += 1 }
    }

    @MainActor
    private final class FailureRecorder {
        var value: DiscoveryFailure?
    }

    func testDiscoveryProbeFailureIsTypedAndObsoleteResultsAreIgnored() {
        let probe = FakeProbe()
        let scheduler = ManualScheduler()
        let transport = NearbyTransport(probe: probe, scheduler: scheduler)
        let failure = FailureRecorder()
        transport.onDiscoveryFailed = { failure.value = $0 }
        transport.host()
        XCTAssertEqual(probe.completions.count, 1)
        transport.browse()
        XCTAssertEqual(probe.completions.count, 2)
        let problem = DiscoveryFailure(operation: .preflight, domain: "DNSService",
                                       code: -65570, detail: "Policy denied")
        probe.completions[0](.failure(problem))
        XCTAssertNil(failure.value)
        probe.completions[1](.failure(problem))
        XCTAssertEqual(failure.value, problem)
        failure.value = nil
        transport.stop()
        probe.completions[1](.failure(problem))
        XCTAssertNil(failure.value)
        XCTAssertGreaterThan(probe.cancels, 0)
    }

    @MainActor
    private final class FeedbackRecorder: FeedbackOutput {
        var events: [FeedbackEvent] = []
        func emit(_ event: FeedbackEvent) { events.append(event) }
    }

    func testFeedbackObeysInjectedPreferencesAndReset() {
        let output = FeedbackRecorder()
        var settings = FeedbackPreferences(sound: true, haptics: false)
        let feedback = GameFeedback(preferences: { settings }, output: output)
        var snapshot = PongSnapshot()
        snapshot.phase = .playing
        feedback.observe(snapshot)
        snapshot.ballVX *= -1
        feedback.observe(snapshot)
        XCTAssertEqual(output.events, [.paddleSound])
        settings = FeedbackPreferences(sound: false, haptics: true)
        snapshot.leftScore += 1
        feedback.observe(snapshot)
        XCTAssertEqual(output.events, [.paddleSound, .pointHaptic])
        feedback.reset()
        snapshot.leftScore += 1
        feedback.observe(snapshot)
        XCTAssertEqual(output.events.count, 2)
    }

    func testExpiredHostInvitationDismissesAlertAndAllowsNewRequest() {
        let network = FakeTransport()
        let model = makeModel(network)
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

    func testPlayAgainRoutesUsingTypedMatchRole() {
        let network = FakeTransport()
        let model = makeModel(network)

        // Solo rematch must never begin network discovery.
        model.playSolo()
        model.playAgain()
        XCTAssertEqual(model.screen, .playing)
        XCTAssertEqual(model.roleLabel, "Solo · Left paddle")
        XCTAssertEqual(network.hostCalls, 0)
        XCTAssertEqual(network.browseCalls, 0)

        // Host/guest rematches follow session role, not presentation copy.
        model.host()
        model.playAgain()
        XCTAssertEqual(model.screen, .hosting)
        XCTAssertEqual(network.hostCalls, 2)
        XCTAssertEqual(network.browseCalls, 0)

        model.browse()
        model.playAgain()
        XCTAssertEqual(model.screen, .browsing)
        XCTAssertEqual(network.browseCalls, 2)

        model.leave()
        model.playAgain()
        XCTAssertEqual(model.screen, .menu)
    }

    func testHostInvitationAndDisconnectResetState() {
        let network = FakeTransport()
        let model = makeModel(network)
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
        let model = makeModel(network)
        model.host()
        network.onDiscoveryFailed?(DiscoveryFailure(operation: .hosting, domain: "DNSService", code: -65570, detail: "Local Network denied"))
        XCTAssertEqual(model.screen, .menu)
        XCTAssertTrue(model.canRetryDiscovery)
        XCTAssertFalse(model.isDisplayClockRunning)
        model.retryDiscovery()
        XCTAssertEqual(network.hostCalls, 2)
        XCTAssertFalse(model.canRetryDiscovery)
    }

    func testBrowsingUsesTransportNeutralPeerIDs() {
        let network = FakeTransport()
        let model = makeModel(network)
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
        let model = makeModel(network)
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
        let model = makeModel(network)
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

    func testStaleDiscoveryTokenRejectsJoinImmediatelyAndKeepsBrowsing() {
        let network = FakeTransport()
        let model = makeModel(network)
        model.browse()
        let stale = NearbyPeer(id: UUID(), displayName: "expired-host")
        network.onPeersChanged?([stale])
        network.joinResult = .unavailable

        model.join(stale)

        XCTAssertEqual(network.joinCalls, [stale])
        XCTAssertEqual(model.screen, .browsing)
        XCTAssertTrue(model.peers.isEmpty, "Remove obsolete discovery token from the visible list")
        XCTAssertFalse(model.isDisplayClockRunning)
        XCTAssertFalse(model.isReady)
        XCTAssertEqual(model.message, "Host no longer available. Select another nearby host.")
        XCTAssertEqual(network.browseCalls, 1, "Browsing must not rotate its session")
        XCTAssertEqual(network.stops, 1, "Rejected join must not stop discovery")
    }

    func testValidJoinInitiatesConnectionWithoutPrematureFailureAlert() {
        let network = FakeTransport()
        let model = makeModel(network)
        model.browse()
        let peer = NearbyPeer(id: UUID(), displayName: "available-host")
        network.onPeersChanged?([peer])

        model.join(peer)

        XCTAssertEqual(network.joinCalls, [peer])
        XCTAssertEqual(model.screen, .connecting)
        XCTAssertNil(model.message)
        XCTAssertFalse(model.isReady)
    }

    func testGuestConnectionFailureBeforeHandshakeReturnsToRetryableMenu() {
        let network = FakeTransport()
        let model = makeModel(network)
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

    func testNonfiniteTouchInputLeavesLocalSimulationUnchanged() {
        let network = FakeTransport()
        let model = makeModel(network)
        model.playSolo()
        let before = model.state

        model.movePaddle(y: .nan)
        model.movePaddle(y: .infinity)
        model.movePaddle(y: -.infinity, finished: true)

        XCTAssertEqual(model.state, before)
        XCTAssertTrue(network.messages.isEmpty,
                      "Invalid touch coordinates must not produce network input")
    }

    func testFinishedGuestMatchRejectsTouchPredictionAndLateRelease() {
        let network = FakeTransport()
        let model = makeModel(network)
        model.browse()
        let hostPeer = NearbyPeer(id: UUID(), displayName: "test-host")
        network.onPeersChanged?([hostPeer])
        model.join(hostPeer)
        network.connected = true
        network.onConnected?()

        var host = MatchCoordinator()
        host.startHosting()
        let hello = network.messages.last!.packet
        let welcome = host.acceptHandshake(hello).response!.packet
        network.onPacket?(welcome)
        let ready = network.messages.last!.packet
        let start = host.acceptHandshake(ready).response!.packet
        network.onPacket?(start)
        let started = network.messages.last!.packet
        XCTAssertTrue(host.acceptHandshake(started).accepted)
        XCTAssertEqual(model.screen, .playing)
        XCTAssertTrue(model.isReady)

        // A local touch is rendered immediately while host gameplay is active.
        model.movePaddle(y: 0.8)
        XCTAssertEqual(model.state.rightPaddleY, 0.8, accuracy: 0.001)
        let sendsBeforeWin = network.messages.count

        var winner = PongSnapshot()
        winner.leftScore = PongGame.winningScore
        winner.phase = .finished
        winner.serveRemaining = 0
        winner.ballVX = 0
        winner.ballVY = 0
        network.onPacket?(MatchMessage(
            kind: .snapshot, matchID: host.matchID!,
            sequence: 1, state: winner))

        // Completion must be published immediately, not delayed until
        // another display refresh with an obsolete predicted paddle.
        XCTAssertEqual(model.state, winner,
                       "The terminal host state replaces local prediction immediately")
        XCTAssertFalse(model.isDisplayClockRunning,
                       "A completed match must not keep waking the display clock")
        model.setInteractive(false)
        model.setInteractive(true)
        XCTAssertFalse(model.isDisplayClockRunning,
                       "Returning to active must not restart a completed match")
        model.movePaddle(y: 0.1, finished: true)
        XCTAssertEqual(model.state, winner,
                       "A late touch must not overwrite the displayed winning state")
        XCTAssertEqual(network.messages.count, sendsBeforeWin,
                       "Completed games must not enqueue a reliable finger release")
        XCTAssertEqual(model.state.phase, .finished)
        XCTAssertTrue(model.isReady)

        model.playAgain()
        XCTAssertEqual(model.screen, .browsing)
        XCTAssertFalse(model.isDisplayClockRunning)
        model.playSolo()
        XCTAssertEqual(model.state.phase, .serving)
        XCTAssertTrue(model.isDisplayClockRunning,
                      "A new match must reactivate the display clock")
    }

    func testLatePacketAfterLeaveCannotRestorePlayingScreen() {
        let network = FakeTransport()
        let model = makeModel(network)
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
        let model = makeModel(network)
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

    func testApplicationMetadataIsPackaged() throws {
        // Read the packaged file, not a device-filtered Bundle dictionary.
        // The source plist alone cannot prove XcodeGen preserved its values.
        let data = try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.micrantha.p0ng.modern")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "1.0")
        XCTAssertEqual(info["CFBundleVersion"] as? String, "1")
        XCTAssertEqual(info["NSBonjourServices"] as? [String], ["_p0ng-lan._tcp"])
        let usage = try XCTUnwrap(info["NSLocalNetworkUsageDescription"] as? String)
        XCTAssertFalse(usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(info["UIRequiredDeviceCapabilities"] as? [String], ["arm64"])
        let phone = try XCTUnwrap(info["UISupportedInterfaceOrientations"] as? [String])
        XCTAssertEqual(Set(phone), Set([
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight"
        ]))
        let launchScreen = try XCTUnwrap(info["UILaunchScreen"] as? [String: Any])
        let colorName = try XCTUnwrap(launchScreen["UIColorName"] as? String)
        XCTAssertEqual(colorName, "LaunchBackground")
        XCTAssertNotNil(UIColor(named: colorName, in: .main, compatibleWith: nil))
        let iPad = try XCTUnwrap(info["UISupportedInterfaceOrientations~ipad"] as? [String])
        XCTAssertEqual(Set(iPad), Set([
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight"
        ]))
        XCTAssertFalse(info["UIRequiresFullScreen"] as? Bool ?? false)
    }

    func testPrivacyManifestIsPackagedAndDeclaresLocalAPIAccess() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        let manifest = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.count, 0)
        let entries = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in entries {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            XCTAssertNil(reasons[category], "Duplicate required-reason category")
            reasons[category] = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }
        XCTAssertEqual(reasons, [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]
        ])
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
        let limiter = LockedPacketIngress(now: { 100 })
        let accepted = CallbackRecorder()
        let overload = CallbackRecorder()
        let references = TestNetworkReferences(
            session: MCSession(peer: MCPeerID(displayName: "local"),
                               securityIdentity: nil, encryptionPreference: .required),
            peer: MCPeerID(displayName: "authorized"),
            unexpected: MCPeerID(displayName: "untrusted"))

        if case .ignored = limiter.admit(session: references.session, from: references.peer) {}
        else { XCTFail("Must not admit before authorization") }
        limiter.authorize(session: references.session, peer: references.peer)
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            let sender = index.isMultiple(of: 2) ? references.peer : references.unexpected
            switch limiter.admit(session: references.session, from: sender) {
            case .admitted(let lease):
                accepted.record()
                limiter.complete(lease)
            case .overloaded: overload.record()
            case .ignored: break
            }
        }
        XCTAssertEqual(accepted.count, 120)
        XCTAssertEqual(overload.count, 1)
        limiter.reset()
        if case .ignored = limiter.admit(session: references.session, from: references.peer) {}
        else { XCTFail("Reset must remove authorization") }
        limiter.authorize(session: references.session, peer: references.unexpected)
        if case .ignored = limiter.admit(session: references.session, from: references.peer) {}
        else { XCTFail("Old peer must not be authorized") }
        if case .admitted(let lease) = limiter.admit(session: references.session, from: references.unexpected) {
            limiter.complete(lease)
        } else { XCTFail("New peer must be authorized") }
        let otherSession = MCSession(peer: MCPeerID(displayName: "other-local"),
                                     securityIdentity: nil, encryptionPreference: .required)
        if case .ignored = limiter.admit(session: otherSession, from: references.unexpected) {}
        else { XCTFail("Different SDK session must not be authorized") }
        limiter.reset()
    }

    private final class AdvancingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0
        func now() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            time += 2
            return time
        }
    }

    func testPendingAdmissionIsBoundedAndResetInvalidatesOldCompletions() {
        let clock = AdvancingClock()
        let limiter = LockedPacketIngress(now: { clock.now() })
        let session = MCSession(peer: MCPeerID(displayName: "local"),
                                securityIdentity: nil, encryptionPreference: .required)
        let peer = MCPeerID(displayName: "peer")
        limiter.authorize(session: session, peer: peer)
        var oldLease: UUID?
        for _ in 0..<PacketIngressWindow.defaultMaximumPacketsPerSecond {
            if case .admitted(let lease) = limiter.admit(session: session, from: peer) {
                oldLease = lease
            } else { XCTFail("Pending budget should allow its capacity") }
        }
        if case .overloaded = limiter.admit(session: session, from: peer) {}
        else { XCTFail("Pending budget must be bounded independently of elapsed time") }
        if case .ignored = limiter.admit(session: session, from: peer) {}
        else { XCTFail("Only one overload notification may be queued") }
        limiter.authorize(session: session, peer: peer)
        for _ in 0..<PacketIngressWindow.defaultMaximumPacketsPerSecond {
            if case .admitted = limiter.admit(session: session, from: peer) {}
            else { XCTFail("New session gets new capacity") }
        }
        if let oldLease { limiter.complete(oldLease) }
        if case .overloaded = limiter.admit(session: session, from: peer) {}
        else { XCTFail("Old completion cannot release new capacity") }
    }
}
