import Foundation
import Combine
import MultipeerConnectivity
import PongCore

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
    private var timer: Timer?
    private var connectionAttempt: UUID?
    private var lastHandshakeAt: TimeInterval = 0
    private var invitationID: UUID?
    private var retryMode: Screen?

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
            default: return // Do not tear down an unrelated or new session.
            }
            self.transport.stop()
            self.match.disconnect()
            self.connectionAttempt = nil
            self.invitation = nil
            self.invitationID = nil
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
            self.screen = .menu
            self.message = reason
            self.transport.stop()
        }
        transport.onPacket = { [weak self] packet in
            guard let self else { return }
            let handshake = self.match.acceptHandshake(packet)
            if handshake.accepted {
                if let response = handshake.response { self.transport.send(response) }
                self.state = self.match.displayed
                if self.match.ready {
                    self.connectionAttempt = nil
                    self.screen = .playing
                }
                return
            }
            guard self.match.receive(packet) else { return }
            self.connectionAttempt = nil
            self.state = self.match.displayed
            if self.match.ready { self.screen = .playing }
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        // Retries recover both missing handshake packets and delegate ordering.
        // The host never runs simulation before the guest acknowledges start.
        if !match.ready, transport.connected,
           screen == .connecting || screen == .hosting {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastHandshakeAt >= 1.0 {
                if let retry = match.handshakeRetry() { transport.send(retry) }
                lastHandshakeAt = now
            }
        }
        guard screen == .playing else { return }
        if let packet = match.tick() { transport.send(packet) }
        if match.role != .guest { state = match.displayed }
    }

    func playSolo() {
        retryMode = nil
        connectionAttempt = nil
        transport.stop()
        match.startSolo()
        state = match.displayed
        screen = .playing
        message = nil
    }

    func host() {
        retryMode = nil
        connectionAttempt = nil
        transport.stop()
        match.startHosting()
        state = match.displayed
        screen = .hosting
        message = nil
        transport.host()
    }

    func browse() {
        retryMode = nil
        connectionAttempt = nil
        transport.stop()
        match.startJoining()
        state = match.displayed
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
        // Ignore timeouts belonging to an earlier connection attempt.
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

    /// UIKit/SwiftUI can set the alert binding false before delivering its
    /// button action. Defer passive dismissal to let the explicit choice win.
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
        if let packet = match.setPaddle(max(0, min(1, y)), finished: finished) {
            transport.send(packet)
        }
        state = match.displayed
    }

    func leave() {
        retryMode = nil
        invitationID = nil
        connectionAttempt = nil
        transport.stop()
        match.disconnect()
        screen = .menu
        message = nil
        invitation = nil
    }

    deinit { timer?.invalidate() }
}
