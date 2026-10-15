import Foundation

/// Pure send-admission decision for the live nearby transport. The session is
/// not considered healthy merely because the coordinator wants to send.
/// A failed reliable control or score must not be silently discarded.
public enum OutboundSendAction: Equatable {
    case ignore
    case transmit
    case terminate
}

public enum OutboundSendPolicy {
    public static let maximumBytes = MatchWireFraming.maximumPayloadBytes

    public static func evaluate(connected: Bool, singleAuthorizedPeer: Bool,
                                quality: SendQuality,
                                encodedByteCount: Int? = nil) -> OutboundSendAction {
        guard connected else { return .ignore }
        guard singleAuthorizedPeer else { return .terminate }
        if let count = encodedByteCount,
           !(1...maximumBytes).contains(count) {
            return quality == .reliable ? .terminate : .ignore
        }
        return .transmit
    }
}
