import Combine
import PongCore

/// Presentation adapter. All application transitions and native effects
/// are owned by the injected interactor, not by SwiftUI.
@MainActor
final class PongViewModel: ObservableObject {
    typealias Screen = SessionInteractor.Screen
    private struct Presentation: Equatable {
        let screen: Screen
        let state: PongSnapshot
        let peers: [NearbyPeer]
        let invitation: String?
        let message: String?
        let canRetry: Bool
        let isGuest: Bool
        let isReady: Bool
        let roleLabel: String

        @MainActor init(_ session: SessionInteractor) {
            screen = session.screen
            state = session.state
            peers = session.peers
            invitation = session.invitation
            message = session.message
            canRetry = session.canRetryDiscovery
            isGuest = session.isGuest
            isReady = session.isReady
            roleLabel = session.roleLabel
        }
    }

    private let interactor: SessionInteractor
    @Published private var presentation: Presentation

    init(interactor: SessionInteractor) {
        self.interactor = interactor
        self.presentation = Presentation(interactor)
        interactor.onChange = { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let next = Presentation(interactor)
        if next != presentation { presentation = next }
    }

    var screen: Screen { presentation.screen }
    var state: PongSnapshot { presentation.state }
    var peers: [NearbyPeer] { presentation.peers }
    var invitation: String? {
        get { presentation.invitation }
        set { interactor.invitation = newValue }
    }
    var message: String? {
        get { presentation.message }
        set { interactor.message = newValue }
    }
    var canRetryDiscovery: Bool { presentation.canRetry }
    var isDisplayClockRunning: Bool { interactor.isDisplayClockRunning }
    var isGuest: Bool { presentation.isGuest }
    var isReady: Bool { presentation.isReady }
    var roleLabel: String { presentation.roleLabel }

    func playSolo() { interactor.playSolo() }
    func host() { interactor.host() }
    func browse() { interactor.browse() }
    func join(_ peer: NearbyPeer) { interactor.join(peer) }
    func respondToInvitation(_ allow: Bool) { interactor.respondToInvitation(allow) }
    func dismissInvitationIfPending() { interactor.dismissInvitationIfPending() }
    func retryDiscovery() { interactor.retryDiscovery() }
    func setInteractive(_ value: Bool) { interactor.setInteractive(value) }
    func movePaddle(y: Double, finished: Bool = false) {
        interactor.movePaddle(y: y, finished: finished)
    }
    func playAgain() { interactor.playAgain() }
    func leave() { interactor.leave() }
}
