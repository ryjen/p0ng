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
            if let welcome = self.match.peerConnected() { self.transport.send(welcome) }
            if self.match.role == .host { self.screen = .playing }
            else { self.screen = .connecting }
        }
        transport.onDisconnected = { [weak self] in
            guard let self else { return }
            self.match.disconnect()
            self.screen = .menu
            self.message = "Peer disconnected. Start another match to play again."
            self.transport.stop()
        }
        transport.onPacket = { [weak self] packet in
            guard let self, self.match.receive(packet) else { return }
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
        transport.stop()
        match.startSolo()
        state = match.displayed
        screen = .playing
        message = nil
    }

    func host() {
        transport.stop()
        match.startHosting()
        state = match.displayed
        screen = .hosting
        message = nil
        transport.host()
    }

    func browse() {
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
        transport.join(peer)
        // A rejected or timed-out invitation must not strand the guest spinner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 23) { [weak self] in
            guard let self, self.screen == .connecting, !self.match.ready else { return }
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
        transport.stop()
        match.disconnect()
        screen = .menu
        message = nil
        invitation = nil
    }

    deinit { timer?.invalidate() }
}
