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
protocol GameTransport: AnyObject {
    var connected: Bool { get }
    var onPeersChanged: (([NearbyPeer]) -> Void)? { get set }
    var onInvitation: ((String) -> Void)? { get set }
    var onConnected: (() -> Void)? { get set }
    var onDisconnected: ((String) -> Void)? { get set }
    var onPacket: ((MatchMessage) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onDiscoveryFailed: ((String) -> Void)? { get set }
    func host()
    func browse()
    func join(_ peer: NearbyPeer)
    func decideInvitation(accept: Bool)
    func send(_ message: OutgoingMessage)
    func stop()
}
