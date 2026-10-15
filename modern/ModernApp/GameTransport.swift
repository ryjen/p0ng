import Foundation
import PongCore

/// Stable, transport-independent discovery identity for the current browse
/// session. These IDs are ephemeral and are not proof of a physical identity.
struct NearbyPeer: Identifiable, Hashable, Sendable {
    let id: UUID
    let displayName: String
}

/// Synchronous initiation only; it does not indicate that a peer connected.
/// In particular, ephemeral discovery tokens may expire before selection.
enum NearbyJoinResult: Sendable, Equatable {
    case invitationSent
    case unavailable
}

/// Callbacks are delivered on the main queue, and the implementation owns
/// discovery/session invalidation. No UI type or MCPeerID leaks into consumers.
/// A fake can simulate protocol failures without physical devices.
@MainActor
protocol GameTransport: AnyObject {
    var connected: Bool { get }
    var onPeersChanged: (@MainActor @Sendable ([NearbyPeer]) -> Void)? { get set }
    var onInvitation: (@MainActor @Sendable (String) -> Void)? { get set }
    var onInvitationExpired: (@MainActor @Sendable () -> Void)? { get set }
    var onConnected: (@MainActor @Sendable () -> Void)? { get set }
    var onDisconnected: (@MainActor @Sendable (String) -> Void)? { get set }
    var onPacket: (@MainActor @Sendable (MatchMessage) -> Void)? { get set }
    var onError: (@MainActor @Sendable (String) -> Void)? { get set }
    var onDiscoveryFailed: (@MainActor @Sendable (String) -> Void)? { get set }
    func host()
    func browse()
    func join(_ peer: NearbyPeer) -> NearbyJoinResult
    func decideInvitation(accept: Bool)
    func send(_ message: OutgoingMessage)
    func stop()
}
