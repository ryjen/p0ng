import Foundation

/// Nearby admission and connection policy shared by the transport and UI.
/// All deadlines are seconds; their safety ordering is covered by portable
/// tests so future tuning cannot accidentally strand an admitted peer.
public enum NearbySessionPolicy {
    public static let unansweredInvitationDeadlineSeconds: TimeInterval = 18
    public static let invitationTimeoutSeconds: TimeInterval = 20
    public static let guestConnectionDeadlineSeconds: TimeInterval = 23
    public static let acceptedConnectionDeadlineSeconds: TimeInterval = 25
}
