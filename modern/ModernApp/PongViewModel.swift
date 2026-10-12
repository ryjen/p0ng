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
        transport.onInvitation = { [weak self] name in self?.invitation = name }
        transport.onError = { [weak self] problem in self?.message = problem }
        transport.onConnected = { [weak self] in
            guard let self else { return }
            if let hello = self.match.makeHello() { self.transport.send(hello) }
            if self.match.role == .guest { self.screen = .connecting }
        }
        transport.onDisconnected = { [weak self] in
            guard let self else { return }
            self.connectionAttempt = nil
            self.match.disconnect()
            self.screen = .menu
            self.message = "Peer disconnected. Start another match to play again."
            self.transport.stop()
        }
        transport.onPacket = { [weak self] packet in
            guard let self else { return }
            if let welcome = self.match.peerConnected(hello: packet) {
                self.transport.send(welcome)
                self.screen = .playing
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
        guard screen == .playing else { return }
        if let packet = match.tick() { transport.send(packet) }
        if match.role != .guest { state = match.displayed }
    }

    func playSolo() {
        connectionAttempt = nil
        transport.stop()
        match.startSolo()
        state = match.displayed
        screen = .playing
        message = nil
    }

    func host() {
        connectionAttempt = nil
        transport.stop()
        match.startHosting()
        state = match.displayed
        screen = .hosting
        message = nil
        transport.host()
    }

    func browse() {
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
        invitation = nil
        transport.decideInvitation(accept: allow)
    }

    func movePaddle(y: Double, finished: Bool = false) {
        guard screen == .playing else { return }
        if let packet = match.setPaddle(max(0, min(1, y)), finished: finished) {
            transport.send(packet)
        }
        state = match.displayed
    }

    func leave() {
        connectionAttempt = nil
        transport.stop()
        match.disconnect()
        screen = .menu
        message = nil
        invitation = nil
    }

    deinit { timer?.invalidate() }
}
