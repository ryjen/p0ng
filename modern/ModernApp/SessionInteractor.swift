import Foundation
import PongCore

@MainActor
final class SessionInteractor {
    enum Screen: Equatable { case menu, hosting, browsing, connecting, playing }
    private enum Phase: Equatable {
        case menu, hosting, browsing, connecting, handshakingHost, handshakingGuest, playing
        var screen: Screen {
            switch self {
            case .menu: .menu
            case .hosting, .handshakingHost: .hosting
            case .browsing: .browsing
            case .connecting, .handshakingGuest: .connecting
            case .playing: .playing
            }
        }
        var handshaking: Bool { self == .handshakingHost || self == .handshakingGuest }
    }

    var onChange: (@MainActor () -> Void)?
    private var phase: Phase = .menu {
        didSet { updateFrameActivity(); onChange?() }
    }
    var screen: Screen { phase.screen }
    private(set) var state = PongSnapshot() { didSet { onChange?() } }
    private(set) var peers: [NearbyPeer] = [] { didSet { onChange?() } }
    var invitation: String? { didSet { onChange?() } }
    var message: String? { didSet { onChange?() } }

    private var match = MatchCoordinator()
    private let transport: GameTransport
    private let clock: FrameClock
    private let now: @MainActor () -> TimeInterval
    private let scheduler: DeadlineScheduling
    private let idleTimer: IdleTimerControlling
    private var cancelDeadline: CancelDeadline?
    private var lastFrameTime: TimeInterval?
    private var interactive = true
    private var frameStepper = FrameStepper()
    private var interpolation = SnapshotInterpolator()
    private var pendingInput = PaddleInputQueue()
    private var paddleReconciliation = PaddleReconciliation()
    private let feedback: GameFeedbacking
    private var connectionAttempt: UUID?
    private var lastHandshakeAt: TimeInterval = 0
    private var invitationID: UUID?
    private var retryMode: Screen? { didSet { onChange?() } }

    #if DEBUG
    private var debugFrameCount = 0
    private var debugDelayedFrames = 0
    private var debugSnapshotCount = 0
    private var debugLastReport: Double = 0
    private var debugFrameTimes = FrameTimingWindow()
    private var debugSnapshotArrivals = SnapshotArrivalWindow()
    #endif

    var canRetryDiscovery: Bool { retryMode != nil }
    var isDisplayClockRunning: Bool { clock.isRunning }
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

    init(transport: GameTransport, clock: FrameClock,
         now: @escaping @MainActor () -> TimeInterval,
         scheduler: DeadlineScheduling, feedback: GameFeedbacking,
         idleTimer: IdleTimerControlling) {
        self.transport = transport
        self.clock = clock
        self.now = now
        self.scheduler = scheduler
        self.feedback = feedback
        self.idleTimer = idleTimer
        // Old discovery callbacks must not repopulate menus after leave or a
        // transition to a different match.
        transport.onPeersChanged = { [weak self] peers in
            guard let self, self.screen == .browsing else { return }
            self.peers = peers
        }
        transport.onInvitation = { [weak self] name in
            guard let self, self.phase == .hosting, self.match.role == .host else { return }
            self.invitationID = UUID()
            self.invitation = name
            self.message = nil // New approval supersedes any expired/error alert.
        }
        transport.onInvitationExpired = { [weak self] in
            guard let self, self.phase == .hosting, self.invitationID != nil else { return }
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
            switch self.phase {
            case .hosting: mode = .hosting
            case .browsing, .connecting: mode = .browsing
            default: return
            }
            self.endSession(retry: mode, message: problem.presentation)
        }
        transport.onConnected = { [weak self] in
            guard let self, self.transport.connected else { return }
            switch self.phase {
            case .hosting: self.phase = .handshakingHost
            case .connecting: self.phase = .handshakingGuest
            default: return
            }
            self.lastHandshakeAt = self.now()
            // Once the transport connects, both roles get the same bounded
            // application handshake window, independent of the display clock.
            self.armDeadline(seconds: NearbySessionPolicy.handshakeDeadlineSeconds) { session in
                guard session.phase.handshaking else { return }
                let retry: Screen = session.match.role == .host ? .hosting : .browsing
                session.endSession(retry: retry, message: "Match handshake timed out. Retry nearby discovery.")
            }
            if self.match.role == .guest, let hello = self.match.handshakeRetry() {
                self.transport.send(hello)
            }
        }
        transport.onDisconnected = { [weak self] reason in
            guard let self, self.phase != .menu,
                  self.match.role == .host || self.match.role == .guest else { return }
            let retry: Screen = self.match.role == .host ? .hosting : .browsing
            self.endSession(retry: retry, message: reason)
        }
        transport.onPacket = { [weak self] packet in
            guard let self, self.phase.handshaking || self.phase == .playing,
                  self.match.role == .host || self.match.role == .guest else { return }
            let hadMatch = self.match.matchID != nil
            let wasReady = self.match.ready
            let handshake = self.match.acceptHandshake(packet)
            if handshake.accepted {
                if let response = handshake.response { self.transport.send(response) }
                guard self.phase.handshaking || self.phase == .playing else { return }
                if self.match.role == .guest, !hadMatch, self.match.matchID != nil {
                    self.interpolation.reset()
                    self.interpolation.append(self.match.displayed, at: self.now())
                }
                self.publish(self.match.displayed)
                if self.match.ready && !wasReady {
                    self.feedback.reset()
                    self.clearDeadline()
                    self.frameStepper.reset()
                    self.lastFrameTime = nil
                    self.phase = .playing
                }
                return
            }
            guard self.match.receive(packet) else { return }
            if self.match.role == .guest {
                // An authoritative win ends local input prediction immediately.
                // No queued movement may leak into a completed match.
                let terminal = self.match.displayed.phase == .finished
                if terminal {
                    self.pendingInput.reset()
                    self.paddleReconciliation.reset()
                    // Drop pre-win interpolation samples so the next display
                    // refresh cannot replay an obsolete running-game frame.
                    self.interpolation.reset()
                }
                self.feedback.observe(self.match.displayed)
                let arrival = self.now()
                self.interpolation.append(self.match.displayed, at: arrival)
                if terminal {
                    // Do not leave a locally predicted paddle or prior score
                    // visible until the next display callback after game-over.
                    self.publish(self.match.displayed)
                }
                #if DEBUG
                self.debugSnapshotArrivals.observe(at: arrival, sequence: packet.sequence)
                self.debugSnapshotCount += 1
                #endif
                // Presentation of received state happens on the next display refresh.
            } else {
                self.publish(self.match.displayed)
            }
        }
        clock.onFrame = { [weak self] timestamp in self?.frame(at: timestamp) }
    }

    private func clearDeadline() {
        connectionAttempt = nil
        cancelDeadline?()
        cancelDeadline = nil
    }

    private func armDeadline(seconds: TimeInterval,
                             _ expired: @escaping @MainActor @Sendable (SessionInteractor) -> Void) {
        clearDeadline()
        let token = UUID()
        connectionAttempt = token
        cancelDeadline = scheduler.schedule(after: seconds) { [weak self] in
            guard let self, self.connectionAttempt == token else { return }
            self.clearDeadline()
            expired(self)
        }
    }

    /// Invalidate the application lifecycle before tearing down the adapter.
    /// Synchronous callbacks from stop cannot re-enter the old session.
    private func endSession(retry: Screen? = nil, message: String? = nil) {
        phase = .menu
        clearDeadline()
        invitationID = nil
        invitation = nil
        peers = []
        match.disconnect()
        resetMotion()
        feedback.reset()
        transport.stop()
        retryMode = retry
        self.message = message
        onChange?()
    }

    private func publish(_ snapshot: PongSnapshot) {
        var display = snapshot
        if match.role == .guest {
            display.rightPaddleY = paddleReconciliation.render(
                authoritative: display.rightPaddleY, at: self.now())
        }
        if state != display {
            let terminalChanged = (state.phase == .finished) != (display.phase == .finished)
            state = display
            if terminalChanged { updateFrameActivity() }
        }
    }

    /// Keep the display clock dormant while browsing, waiting for a peer,
    /// or showing a completed match. A connected-but-not-ready session still
    /// needs one-second handshake retries.
    private func updateFrameActivity() {
        let active = interactive && ((phase == .playing && state.phase != .finished) ||
                                     (transport.connected && phase.handshaking))
        let keepAwake = interactive && phase != .menu
            && (match.role == .host || match.role == .guest)
            && (phase != .playing || state.phase != .finished)
        idleTimer.setPreventingSleep(keepAwake)
        guard clock.isRunning != active else { return }
        clock.setRunning(active)
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
    func frame(at now: TimeInterval) {
        guard interactive, clock.isRunning else { return }
        let elapsed = lastFrameTime.map { now - $0 } ?? 0
        lastFrameTime = now
        if !match.ready, transport.connected,
           phase.handshaking {
            if now - lastHandshakeAt >= 1.0 {
                if let retry = match.handshakeRetry() { transport.send(retry) }
                lastHandshakeAt = now
            }
        }
        guard interactive, phase == .playing, state.phase != .finished else { return }

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
            for packet in outgoing.drain() {
                guard phase == .playing else { break }
                transport.send(packet)
            }
            publish(match.displayed)
        }
    }

    /// Rematch navigation follows the authoritative typed role, not display
    /// copy. The view exposes this action after a completed match.
    func playAgain() {
        switch match.role {
        case .solo: playSolo()
        case .host: host()
        case .guest: browse()
        case .idle: break
        }
    }

    func playSolo() {
        endSession()
        match.startSolo()
        resetMotion()
        feedback.reset()
        publish(match.displayed)
        phase = .playing
        message = nil
    }

    func host() {
        endSession()
        match.startHosting()
        resetMotion()
        feedback.reset()
        publish(match.displayed)
        phase = .hosting
        message = nil
        transport.host()
    }

    func browse() {
        endSession()
        match.startJoining()
        resetMotion()
        feedback.reset()
        publish(match.displayed)
        phase = .browsing
        message = nil
        transport.browse()
    }

    func join(_ peer: NearbyPeer) {
        guard screen == .browsing else { return }
        phase = .connecting
        guard transport.join(peer) == .invitationSent else {
            // A discovered peer may disappear before the user selects it.
            // Do not start a connection timeout for an invitation never sent.
            guard phase == .connecting else { return }
            clearDeadline()
            peers.removeAll { $0.id == peer.id }
            phase = .browsing
            message = "Host no longer available. Select another nearby host."
            return
        }
        // A synchronous connected/failure callback may already have moved
        // the state; do not overwrite its newer deadline or error.
        guard phase == .connecting else { return }
        message = nil
        armDeadline(seconds: NearbySessionPolicy.guestConnectionDeadlineSeconds) { session in
            guard session.phase == .connecting else { return }
            session.browse()
            session.message = "Connection timed out. Select a nearby host to retry."
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
        _ = scheduler.schedule(after: 0) { [weak self] in
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
        guard interactive, phase == .playing, match.ready,
              match.displayed.phase != .finished, y.isFinite else { return }
        let position = min(1 - PongGame.paddleHeight / 2,
                           max(PongGame.paddleHeight / 2, y))
        if match.role == .guest {
            paddleReconciliation.update(y: position, finished: finished,
                                        at: self.now())
            pendingInput.offer(y: position, finished: finished)
            var display = state
            display.rightPaddleY = position
            publish(display)
            // The final finger release must be sent reliably even if the
            // display link pauses just after the drag ends.
            if finished, let input = pendingInput.take(at: self.now()),
               let packet = match.setPaddle(input.y, finished: input.finished) {
                transport.send(packet)
            }
        } else {
            _ = match.setPaddle(position, finished: finished)
            publish(match.displayed)
        }
    }

    func leave() { endSession() }
}
