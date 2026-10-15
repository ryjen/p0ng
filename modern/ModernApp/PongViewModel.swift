import Foundation
import Combine
import QuartzCore
import PongCore

/// Keep CADisplayLink teardown off the view model's nonisolated deinit.
/// The runloop owns the link, so invalidate on the main queue even if ARC
/// releases the lifetime owner from another executor. Only MainActor code
/// otherwise accesses the reference.
private struct MainQueueDisplayLink: @unchecked Sendable {
    let link: CADisplayLink
}

private final class DisplayLinkLifetime {
    private let token: MainQueueDisplayLink
    init(link: CADisplayLink) { token = MainQueueDisplayLink(link: link) }
    deinit {
        let token = token
        DispatchQueue.main.async { token.link.invalidate() }
    }
}

/// Weak proxy breaks CADisplayLink's retain cycle with its target.
@MainActor
private final class FrameTarget: NSObject {
    weak var owner: PongViewModel?
    @objc func frame(_ link: CADisplayLink) { owner?.frame(link) }
}

@MainActor
final class PongViewModel: ObservableObject {
    enum Screen { case menu, hosting, browsing, connecting, playing }

    @Published private(set) var screen: Screen = .menu {
        didSet { updateFrameActivity() }
    }
    @Published private(set) var state = PongSnapshot()
    @Published private(set) var peers: [NearbyPeer] = []
    @Published var invitation: String?
    @Published var message: String?

    private var match = MatchCoordinator()
    private let transport: GameTransport
    private let frameTarget = FrameTarget()
    private var displayLink: CADisplayLink?
    private var displayLinkLifetime: DisplayLinkLifetime?
    private var lastFrameTime: CFTimeInterval?
    private var interactive = true
    private var frameStepper = FrameStepper()
    private var interpolation = SnapshotInterpolator()
    private var pendingInput = PaddleInputQueue()
    private var paddleReconciliation = PaddleReconciliation()
    private let feedback = GameFeedback()
    private var connectionAttempt: UUID?
    private var lastHandshakeAt: TimeInterval = 0
    private var invitationID: UUID?
    private var retryMode: Screen?

    #if DEBUG
    private var debugFrameCount = 0
    private var debugDelayedFrames = 0
    private var debugSnapshotCount = 0
    private var debugLastReport: Double = 0
    private var debugFrameTimes = FrameTimingWindow()
    private var debugSnapshotArrivals = SnapshotArrivalWindow()
    #endif

    var canRetryDiscovery: Bool { retryMode != nil }
    var isDisplayClockRunning: Bool { displayLink?.isPaused == false }
    var isGuest: Bool { match.role == .guest }
    var isReady: Bool { match.ready }
    var roleLabel: String {
        switch match.role {
        case .solo: return "Solo · Left paddle"
        case .host: return "Host · Left paddle"
        case .guest: return "Guest · Right paddle"
        case .idle: return ""
        }
    }

    init(transport: GameTransport = NearbyTransport()) {
        self.transport = transport
        // Old discovery callbacks must not repopulate menus after leave or a
        // transition to a different match.
        transport.onPeersChanged = { [weak self] peers in
            guard let self, self.screen == .browsing else { return }
            self.peers = peers
        }
        transport.onInvitation = { [weak self] name in
            guard let self, self.screen == .hosting, self.match.role == .host else { return }
            self.invitationID = UUID()
            self.invitation = name
            self.message = nil // New approval supersedes any expired/error alert.
        }
        transport.onInvitationExpired = { [weak self] in
            guard let self, self.screen == .hosting, self.invitationID != nil else { return }
            self.invitationID = nil
            self.invitation = nil
            self.message = "Join request expired. A nearby player may try again."
        }
        transport.onError = { [weak self] problem in
            guard let self, self.screen != .menu else { return }
            self.message = problem
        }
        transport.onDiscoveryFailed = { [weak self] problem in
            guard let self else { return }
            let mode: Screen
            switch self.screen {
            case .hosting: mode = .hosting
            case .browsing, .connecting: mode = .browsing
            default: return
            }
            self.transport.stop()
            self.match.disconnect()
            self.connectionAttempt = nil
            self.invitation = nil
            self.invitationID = nil
            self.resetMotion()
            self.feedback.reset()
            self.retryMode = mode
            self.screen = .menu
            self.message = "Nearby discovery failed: \(problem)"
        }
        transport.onConnected = { [weak self] in
            guard let self,
                  (self.screen == .hosting && self.match.role == .host) ||
                  (self.screen == .connecting && self.match.role == .guest) else { return }
            self.updateFrameActivity()
            if self.match.role == .guest {
                self.screen = .connecting
                if let hello = self.match.handshakeRetry() { self.transport.send(hello) }
            }
            self.lastHandshakeAt = CACurrentMediaTime()
        }
        transport.onDisconnected = { [weak self] reason in
            // A delayed previous-session error cannot cancel solo play or a
            // newly returned-to-menu screen.
            guard let self, self.screen != .menu,
                  self.match.role == .host || self.match.role == .guest else { return }
            self.connectionAttempt = nil
            self.invitationID = nil
            self.invitation = nil
            self.peers = []
            self.match.disconnect()
            self.resetMotion()
            self.feedback.reset()
            self.screen = .menu
            self.message = reason
            self.transport.stop()
        }
        transport.onPacket = { [weak self] packet in
            guard let self, self.match.role == .host || self.match.role == .guest else { return }
            let hadMatch = self.match.matchID != nil
            let wasReady = self.match.ready
            let handshake = self.match.acceptHandshake(packet)
            if handshake.accepted {
                if let response = handshake.response { self.transport.send(response) }
                if self.match.role == .guest, !hadMatch, self.match.matchID != nil {
                    self.interpolation.reset()
                    self.interpolation.append(self.match.displayed, at: CACurrentMediaTime())
                }
                self.publish(self.match.displayed)
                if self.match.ready && !wasReady {
                    self.feedback.reset()
                    self.connectionAttempt = nil
                    self.frameStepper.reset()
                    self.lastFrameTime = nil
                    self.screen = .playing
                }
                return
            }
            guard self.match.receive(packet) else { return }
            if self.match.role == .guest {
                self.feedback.observe(self.match.displayed)
                let arrival = CACurrentMediaTime()
                self.interpolation.append(self.match.displayed, at: arrival)
                #if DEBUG
                self.debugSnapshotArrivals.observe(at: arrival, sequence: packet.sequence)
                self.debugSnapshotCount += 1
                #endif
                // Presentation of received state happens on the next display refresh.
            } else {
                self.publish(self.match.displayed)
            }
        }
        frameTarget.owner = self
        let link = CADisplayLink(target: frameTarget, selector: #selector(FrameTarget.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
        displayLinkLifetime = DisplayLinkLifetime(link: link)
    }

    private func publish(_ snapshot: PongSnapshot) {
        var display = snapshot
        if match.role == .guest {
            display.rightPaddleY = paddleReconciliation.render(
                authoritative: display.rightPaddleY, at: CACurrentMediaTime())
        }
        if state != display { state = display }
    }

    /// Keep the display clock dormant while browsing or waiting for a peer.
    /// A connected-but-not-ready session still needs one-second handshake retries.
    private func updateFrameActivity() {
        let active = interactive && (screen == .playing ||
            (transport.connected && (screen == .hosting || screen == .connecting)))
        guard let link = displayLink, link.isPaused == active else { return }
        link.isPaused = !active
        lastFrameTime = nil // Resuming must not create catch-up simulation bursts.
    }

    /// Suspend frame-driven simulation while the app is temporarily inactive,
    /// without treating a brief interruption as an immediate disconnection.
    /// Returning to active always resets the timing baseline.
    func setInteractive(_ value: Bool) {
        guard interactive != value else { return }
        interactive = value
        lastFrameTime = nil
        frameStepper.reset()
        updateFrameActivity()
    }

    private func resetMotion() {
        frameStepper.reset()
        lastFrameTime = nil
        interpolation.reset()
        pendingInput.reset()
        paddleReconciliation.reset()
        #if DEBUG
        debugSnapshotArrivals.reset()
        #endif
    }

    /// Called directly on the main actor, once per native display refresh.
    /// No per-frame unbounded Task scheduling.
    func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = lastFrameTime.map { now - $0 } ?? 0
        lastFrameTime = now
        if !match.ready, transport.connected,
           (screen == .connecting || screen == .hosting) {
            if now - lastHandshakeAt >= 1.0 {
                if let retry = match.handshakeRetry() { transport.send(retry) }
                lastHandshakeAt = now
            }
        }
        guard screen == .playing else { return }

        #if DEBUG
        debugFrameCount += 1
        if elapsed > 1.0 / 40.0 { debugDelayedFrames += 1 }
        debugFrameTimes.add(elapsed)
        if now - debugLastReport >= 5 {
            // No identifiers or packet contents are logged.
            let timing = debugFrameTimes.summary()
            let arrivals = debugSnapshotArrivals.summary()
            let variation = debugSnapshotArrivals.variationSummary()
            print("p0ng perf frames=\(debugFrameCount) delayed=\(debugDelayedFrames) snapshots=\(debugSnapshotCount) frameP50ms=\(timing?.p50Milliseconds ?? 0) frameP95ms=\(timing?.p95Milliseconds ?? 0) frameP99ms=\(timing?.p99Milliseconds ?? 0) snapshotGapP50ms=\(arrivals?.p50Milliseconds ?? 0) snapshotGapP95ms=\(arrivals?.p95Milliseconds ?? 0) snapshotGapP99ms=\(arrivals?.p99Milliseconds ?? 0) snapshotVariationP95ms=\(variation?.p95Milliseconds ?? 0) snapshotSequenceGaps=\(debugSnapshotArrivals.sequenceGaps) discardedSimSeconds=\(frameStepper.discardedSeconds)")
            debugFrameTimes.reset()
            debugSnapshotArrivals.clearSamples()
            debugFrameCount = 0
            debugDelayedFrames = 0
            debugSnapshotCount = 0
            debugLastReport = now
        }
        #endif

        if match.role == .guest {
            if let input = pendingInput.take(at: now),
               let packet = match.setPaddle(input.y, finished: input.finished) {
                transport.send(packet)
            }
            publish(interpolation.sample(at: now) ?? match.displayed)
        } else {
            var outgoing = SnapshotPacketBatch()
            for _ in 0..<frameStepper.advance(elapsed: elapsed) {
                if let packet = match.tick() { outgoing.append(packet) }
                feedback.observe(match.displayed)
            }
            for packet in outgoing.drain() { transport.send(packet) }
            publish(match.displayed)
        }
    }

    func playSolo() {
        retryMode = nil
        connectionAttempt = nil
        transport.stop()
        match.startSolo()
        resetMotion()
        feedback.reset()
        publish(match.displayed)
        screen = .playing
        message = nil
    }

    func host() {
        retryMode = nil
        connectionAttempt = nil
        transport.stop()
        match.startHosting()
        resetMotion()
        feedback.reset()
        publish(match.displayed)
        screen = .hosting
        message = nil
        transport.host()
    }

    func browse() {
        retryMode = nil
        connectionAttempt = nil
        transport.stop()
        match.startJoining()
        resetMotion()
        feedback.reset()
        publish(match.displayed)
        screen = .browsing
        message = nil
        transport.browse()
    }

    func join(_ peer: NearbyPeer) {
        guard screen == .browsing else { return }
        screen = .connecting
        let attempt = UUID()
        connectionAttempt = attempt
        guard transport.join(peer) == .invitationSent else {
            // A discovered peer may disappear before the user selects it.
            // Do not start a connection timeout for an invitation never sent.
            connectionAttempt = nil
            peers.removeAll { $0.id == peer.id }
            screen = .browsing
            message = "Host no longer available. Select another nearby host."
            return
        }
        message = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + NearbySessionPolicy.guestConnectionDeadlineSeconds) { [weak self] in
            guard let self, self.connectionAttempt == attempt,
                  self.screen == .connecting, !self.match.ready else { return }
            self.browse()
            self.message = "Connection timed out. Select a nearby host to retry."
        }
    }

    func respondToInvitation(_ allow: Bool) {
        guard invitationID != nil else { return }
        invitationID = nil
        invitation = nil
        transport.decideInvitation(accept: allow)
    }

    func dismissInvitationIfPending() {
        guard let token = invitationID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.invitationID == token else { return }
            self.respondToInvitation(false)
        }
    }

    func retryDiscovery() {
        guard let mode = retryMode else { return }
        retryMode = nil
        if mode == .hosting { host() }
        else { browse() }
    }

    func movePaddle(y: Double, finished: Bool = false) {
        guard screen == .playing else { return }
        let position = min(1 - PongGame.paddleHeight / 2,
                           max(PongGame.paddleHeight / 2, y))
        if match.role == .guest {
            paddleReconciliation.update(y: position, finished: finished,
                                        at: CACurrentMediaTime())
            pendingInput.offer(y: position, finished: finished)
            var display = state
            display.rightPaddleY = position
            publish(display)
            // The final finger release must be sent reliably even if the
            // display link pauses just after the drag ends.
            if finished, let input = pendingInput.take(at: CACurrentMediaTime()),
               let packet = match.setPaddle(input.y, finished: input.finished) {
                transport.send(packet)
            }
        } else {
            _ = match.setPaddle(position, finished: finished)
            publish(match.displayed)
        }
    }

    func leave() {
        retryMode = nil
        invitationID = nil
        connectionAttempt = nil
        transport.stop()
        match.disconnect()
        resetMotion()
        feedback.reset()
        screen = .menu
        peers = []
        message = nil
        invitation = nil
    }

}
