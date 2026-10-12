import Foundation

/// Both authenticated Game Center participants can independently derive
/// the same authoritative host. Pass opaque, non-empty GKPlayer.gamePlayerID
/// values; do not use mutable player aliases/display names.
public enum OnlineHostElection {
    /// Returns nil on invalid, missing, or duplicate identities.
    /// UTF-8 byte ordering is deterministic across devices and locales.
    public static func hostID(_ local: String, _ remote: String) -> String? {
        guard !local.isEmpty, !remote.isEmpty, local != remote,
              local.utf8.count <= 256, remote.utf8.count <= 256 else { return nil }
        return local.utf8.lexicographicallyPrecedes(remote.utf8) ? local : remote
    }

    public static func localIsHost(_ local: String, _ remote: String) -> Bool? {
        guard let id = hostID(local, remote) else { return nil }
        return id == local
    }
}
