import Foundation

/// Stable application protocol. MCSession provides transport encryption; this adds
/// explicit roles, protocol versioning, match identity and replay rejection.
public struct MatchMessage: Codable, Equatable, Sendable {
    public static let protocolVersion = 2

    public enum Kind: String, Codable, Sendable {
        case hello, welcome, ready, start, started, input, snapshot, leave
    }

    public var version: Int
    public var kind: Kind
    public var matchID: UUID
    public var sequence: UInt64
    public var paddleY: Double?
    public var state: PongSnapshot?

    public init(kind: Kind, matchID: UUID, sequence: UInt64,
                paddleY: Double? = nil, state: PongSnapshot? = nil) {
        self.version = Self.protocolVersion
        self.kind = kind
        self.matchID = matchID
        self.sequence = sequence
        self.paddleY = paddleY
        self.state = state
    }
}

public enum SendQuality: Sendable { case reliable, realtime }

public struct OutgoingMessage: Sendable {
    public let packet: MatchMessage
    public let quality: SendQuality
}

/// Single-writer simulation: host owns physics, scoring and match lifecycle.
/// The guest may submit only right-paddle inputs and render host snapshots.
/// The host is the sole simulation writer. A three-way start barrier prevents
/// the host simulating before the guest has received the start message:
/// hello -> welcome -> ready -> start -> started (acknowledgement).
/// All handshake messages are reliable and can be repeated without restarting.
public struct MatchCoordinator {
    public enum Role: Equatable { case idle, solo, host, guest }
    public private(set) var role: Role = .idle
    public private(set) var game = PongGame()
    public private(set) var displayed = PongSnapshot()
    public private(set) var matchID: UUID?
    public private(set) var ready = false

    private var sequence: UInt64 = 0
    private var lastInput: UInt64 = 0
    private var lastSnapshot: UInt64 = 0
    private var frames = 0
    private var hostReceivedHello = false
    private var hostSentStart = false

    public init() {}

    public mutating func startSolo() {
        reset(for: .solo)
        ready = true
    }

    public mutating func startHosting() {
        reset(for: .host)
        matchID = UUID()
    }

    public mutating func startJoining() { reset(for: .guest) }

    public mutating func disconnect() { reset(for: .idle) }

    private mutating func reset(for role: Role) {
        self.role = role
        self.game = PongGame()
        self.displayed = game.snapshot
        self.matchID = nil
        self.ready = false
        self.sequence = 0
        self.lastInput = 0
        self.lastSnapshot = 0
        self.frames = 0
        self.hostReceivedHello = false
        self.hostSentStart = false
    }

    private func response(_ kind: MatchMessage.Kind, state: PongSnapshot? = nil) -> OutgoingMessage? {
        guard let matchID else { return nil }
        return OutgoingMessage(packet: MatchMessage(kind: kind, matchID: matchID,
                                                    sequence: 0, state: state),
                               quality: .reliable)
    }

    /// Retry at most once per second while connecting; never simulates a frame.
    public func handshakeRetry() -> OutgoingMessage? {
        guard !ready else { return nil }
        switch role {
        case .guest:
            if matchID == nil {
                return OutgoingMessage(packet: MatchMessage(kind: .hello,
                                                            matchID: UUID(), sequence: 0),
                                       quality: .reliable)
            }
            return response(.ready)
        case .host:
            guard hostReceivedHello else { return nil }
            return hostSentStart ? response(.start) : response(.welcome, state: game.snapshot)
        case .solo, .idle:
            return nil
        }
    }

    /// Returns whether a valid handshake message was applied and a possible
    /// outbound acknowledgement. Replayed messages resend the same response.
    public mutating func acceptHandshake(_ m: MatchMessage)
        -> (accepted: Bool, response: OutgoingMessage?) {
        guard m.version == MatchMessage.protocolVersion, m.sequence == 0,
              m.paddleY == nil else { return (false, nil) }

        switch role {
        case .host:
            guard let matchID else { return (false, nil) }
            switch m.kind {
            case .hello where m.state == nil && !ready:
                hostReceivedHello = true
                return (true, response(.welcome, state: game.snapshot))
            case .ready where m.state == nil && m.matchID == matchID
                                   && hostReceivedHello && !ready:
                hostSentStart = true
                return (true, response(.start))
            case .started where m.state == nil && m.matchID == matchID
                                     && hostSentStart:
                ready = true
                return (true, nil)
            default: return (false, nil)
            }
        case .guest:
            switch m.kind {
            case .welcome:
                guard !ready, let state = m.state, Self.valid(state) else {
                    return (false, nil)
                }
                if matchID == nil {
                    matchID = m.matchID
                    displayed = state
                } else if matchID != m.matchID {
                    return (false, nil)
                }
                return (true, response(.ready))
            case .start where m.state == nil && m.matchID == matchID:
                // Even after joining the game, acknowledge repeated starts;
                // this recovers from a dropped 'started' acknowledgement.
                ready = true
                return (true, response(.started))
            default: return (false, nil)
            }
        case .solo, .idle:
            return (false, nil)
        }
    }

    public mutating func setPaddle(_ y: Double, finished: Bool = false) -> OutgoingMessage? {
        guard ready, displayed.phase != .finished, y.isFinite, (0...1).contains(y) else { return nil }
        switch role {
        case .host, .solo:
            game.move(.left, to: y)
            displayed = game.snapshot
            return nil
        case .guest:
            guard let matchID else { return nil }
            sequence &+= 1
            displayed.rightPaddleY = min(1 - PongGame.paddleHeight / 2,
                                         max(PongGame.paddleHeight / 2, y))
            return OutgoingMessage(packet: MatchMessage(kind: .input, matchID: matchID,
                                                        sequence: sequence, paddleY: y),
                                   quality: finished ? .reliable : .realtime)
        case .idle: return nil
        }
    }

    /// Call at a fixed 60 Hz. Host sends state at 30 Hz plus reliable phase changes.
    public mutating func tick() -> OutgoingMessage? {
        guard ready, role == .solo || role == .host,
              displayed.phase != .finished else { return nil }
        let before = game.snapshot
        game.tick(1.0 / 60.0, againstComputer: role == .solo)
        displayed = game.snapshot
        guard role == .host, let matchID else { return nil }
        frames += 1
        let critical = before.phase != displayed.phase ||
                       before.leftScore != displayed.leftScore ||
                       before.rightScore != displayed.rightScore
        guard critical || frames % 2 == 0 else { return nil }
        sequence &+= 1
        return OutgoingMessage(packet: MatchMessage(kind: .snapshot, matchID: matchID,
                                                    sequence: sequence, state: displayed),
                               quality: critical ? .reliable : .realtime)
    }

    /// A guest cannot send authoritative state; host-only messages are ignored by host.
    @discardableResult
    public mutating func receive(_ message: MatchMessage) -> Bool {
        guard message.version == MatchMessage.protocolVersion else { return false }
        switch role {
        case .host:
            guard ready, game.snapshot.phase != .finished,
                  message.kind == .input, message.matchID == matchID,
                  message.state == nil, message.sequence > lastInput,
                  let y = message.paddleY, y.isFinite, (0...1).contains(y) else { return false }
            lastInput = message.sequence
            game.move(.right, to: y)
            displayed = game.snapshot
            return true
        case .guest:
            guard ready, message.kind == .snapshot, message.matchID == matchID,
                  message.sequence > lastSnapshot, message.paddleY == nil,
                  let state = message.state, Self.valid(state) else { return false }
            lastSnapshot = message.sequence
            displayed = state
            return true
        case .solo, .idle: return false
        }
    }

    private static func valid(_ s: PongSnapshot) -> Bool {
        let values = [s.ballX, s.ballY, s.ballVX, s.ballVY,
                      s.leftPaddleY, s.rightPaddleY]
        return values.allSatisfy { $0.isFinite && abs($0) <= 4 } &&
            s.serveRemaining.isFinite &&
            (0...PongGame.serveDurationSeconds).contains(s.serveRemaining) &&
            (0...PongGame.winningScore).contains(s.leftScore) &&
            (0...PongGame.winningScore).contains(s.rightScore) &&
            (0...1).contains(s.leftPaddleY) &&
            (0...1).contains(s.rightPaddleY)
    }
}
