import Foundation
import PongCore

/// Stable, transport-independent discovery identity for the current browse
/// session. These IDs are ephemeral and are not proof of a physical identity.
struct NearbyPeer: Identifiable, Hashable {
    let id: UUID
    let displayName: String
}

/// Callbacks are delivered on the main queue, and the implementation owns
/// discovery/session invalidation. No UI type or MCPeerID leaks into consumers.
/// A fake can simulate protocol failures without physical devices.
@MainActor
protocol GameTransport: AnyObject {
    var connected: Bool { get }
    var onPeersChanged: (@MainActor ([NearbyPeer]) -> Void)? { get set }
    var onInvitation: (@MainActor (String) -> Void)? { get set }
    var onConnected: (@MainActor () -> Void)? { get set }
    var onDisconnected: (@MainActor (String) -> Void)? { get set }
    var onPacket: (@MainActor (MatchMessage) -> Void)? { get set }
    var onError: (@MainActor (String) -> Void)? { get set }
    var onDiscoveryFailed: (@MainActor (String) -> Void)? { get set }
    func host()
    func browse()
    func join(_ peer: NearbyPeer)
    func decideInvitation(accept: Bool)
    func send(_ message: OutgoingMessage)
    func stop()
}
