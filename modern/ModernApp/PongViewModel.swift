import Foundation
import Combine
import QuartzCore
import MultipeerConnectivity
import PongCore

/// Weak proxy breaks CADisplayLink's retain cycle with its target.
@MainActor
private final class FrameTarget: NSObject {
    weak var owner: PongViewModel?
    @objc func frame(_ link: CADisplayLink) { owner?.frame(link) }
}

@MainActor
final class PongViewModel: ObservableObject {
    enum Screen { case menu, hosting, browsing, connecting, playing }

    @Published private(set) var screen: Screen = .menu
    @Published private(set) var state = PongSnapshot()
    @Published private(set) var peers: [MCPeerID] = []
    @Published var invitation: String?
    @Published var message: String?

    private var match = MatchCoordinator()
    private let transport = NearbyTransport()
    private let frameTarget = FrameTarget()
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var frameStepper = FrameStepper()
    private var interpolation = SnapshotInterpolator()
    private var pendingInput = PaddleInputQueue()
    private var localPaddleY: Double?
    private var connectionAttempt: UUID?
    private var lastHandshakeAt: TimeInterval = 0
    private var invitationID: UUID?
    private var retryMode: Screen?

    #if DEBUG
    private var debugFrameCount = 0
    private var debugDelayedFrames = 0
    private var debugSnapshotCount = 0
    private var debugLastReport: Double = 0
    #endif

    var canRetryDiscovery: Bool { retryMode != nil }
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

    init() {
        transport.onPeersChanged = { [weak self] peers in self?.peers = peers }
        transport.onInvitation = { [weak self] name in
            self?.invitationID = UUID()
            self?.invitation = name
        }
        transport.onError = { [weak self] problem in self?.message = problem }
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
            self.retryMode = mode
            self.screen = .menu
            self.message = "Nearby discovery failed: \(problem)"
        }
        transport.onConnected = { [weak self] in
            guard let self else { return }
            if self.match.role == .guest {
                self.screen = .connecting
                if let hello = self.match.handshakeRetry() { self.transport.send(hello) }
            }
            self.lastHandshakeAt = ProcessInfo.processInfo.systemUptime
        }
        transport.onDisconnected = { [weak self] reason in
            guard let self else { return }
            self.connectionAttempt = nil
            self.match.disconnect()
            self.resetMotion()
            self.screen = .menu
            self.message = reason
            self.transport.stop()
        }
        transport.onPacket = { [weak self] packet in
            guard let self else { return }
            let hadMatch = self.match.matchID != nil
            let handshake = self.match.acceptHandshake(packet)
            if handshake.accepted {
                if let response = handshake.response { self.transport.send(response) }
                if self.match.role == .guest, !hadMatch, self.match.matchID != nil {
                    self.interpolation.reset()
                    self.interpolation.append(self.match.displayed, at: CACurrentMediaTime())
                }
                self.publish(self.match.displayed)
                if self.match.ready {
                    self.connectionAttempt = nil
                    self.frameStepper.reset()
                    self.lastFrameTime = nil
                    self.screen = .playing
                }
                return
            }
            guard self.match.receive(packet) else { return }
            if self.match.role == .guest {
                self.interpolation.append(self.match.displayed, at: CACurrentMediaTime())
                #if DEBUG
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
        displayLink = link
    }

    private func publish(_ snapshot: PongSnapshot) {
        var display = snapshot
        if match.role == .guest, let y = localPaddleY {
            // Never overwrite the finger position with a delayed host snapshot.
            display.rightPaddleY = y
        }
        if state != display { state = display }
    }

    private func resetMotion() {
        frameStepper.reset()
        lastFrameTime = nil
        interpolation.reset()
        pendingInput.reset()
        localPaddleY = nil
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
        if now - debugLastReport >= 5 {
            // No identifiers or packet contents are logged.
            print("p0ng perf frames=\(debugFrameCount) delayed=\(debugDelayedFrames) snapshots=\(debugSnapshotCount) discardedSimSeconds=\(frameStepper.discardedSeconds)")
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
            for _ in 0..<frameStepper.advance(elapsed: elapsed) {
                if let packet = match.tick() { transport.send(packet) }
            }
            publish(match.displayed)
        }
    }

    func playSolo() {
        retryMode = nil
        connectionAttempt = nil
        transport.stop()
        match.startSolo()
        resetMotion()
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
        publish(match.displayed)
        screen = .browsing
        message = nil
        transport.browse()
    }

    func join(_ peer: MCPeerID) {
        guard screen == .browsing else { return }
        screen = .connecting
        let attempt = UUID()
        connectionAttempt = attempt
        transport.join(peer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 23) { [weak self] in
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
            localPaddleY = position
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
        screen = .menu
        message = nil
        invitation = nil
    }

    deinit { displayLink?.invalidate() }
}
