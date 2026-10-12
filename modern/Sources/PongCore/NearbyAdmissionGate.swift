/// Small, Foundation-only admission state machine for a two-peer nearby match.
/// Network delegate identity checks remain in NearbyTransport.
public struct NearbyAdmissionGate: Sendable {
    public enum State: Equatable, Sendable {
        case available, pending, accepted, connected
    }

    public private(set) var state: State = .available

    public init() {}

    public mutating func offer() -> Bool {
        guard state == .available else { return false }
        state = .pending
        return true
    }

    /// Returns false if this invitation was already decided or invalidated.
    public mutating func resolve(accept: Bool) -> Bool {
        guard state == .pending else { return false }
        state = accept ? .accepted : .available
        return true
    }

    public mutating func didConnect() -> Bool {
        guard state == .accepted || state == .connected else { return false }
        state = .connected
        return true
    }

    public mutating func reset() { state = .available }
}
