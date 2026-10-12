import Foundation

/// Stable application protocol. MCSession provides transport encryption; this adds
/// explicit roles, protocol versioning, match identity and replay rejection.
public struct MatchMessage: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public enum Kind: String, Codable, Sendable {
        case hello, welcome, input, snapshot, leave
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
    }

    /// The guest sends hello only after its transport is connected, preventing
    /// a host welcome from racing guest session establishment.
    public func makeHello() -> OutgoingMessage? {
        guard role == .guest, !ready, matchID == nil else { return nil }
        return OutgoingMessage(packet: MatchMessage(kind: .hello, matchID: UUID(),
                                                   sequence: 0), quality: .reliable)
    }

    public mutating func peerConnected(hello: MatchMessage) -> OutgoingMessage? {
        guard role == .host, !ready, let matchID,
              hello.version == MatchMessage.protocolVersion,
              hello.kind == .hello, hello.sequence == 0,
              hello.paddleY == nil, hello.state == nil else { return nil }
        ready = true
        return OutgoingMessage(packet: MatchMessage(kind: .welcome, matchID: matchID,
                                                   sequence: 0, state: game.snapshot),
                               quality: .reliable)
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

    /// Call at a fixed 60 Hz. Host snapshots at 30 Hz, with reliable phase/score changes.
    public mutating func tick() -> OutgoingMessage? {
        guard ready, role == .solo || role == .host else { return nil }
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

    /// Returns whether a valid message was applied. A guest may never send authoritative state.
    @discardableResult
    public mutating func receive(_ message: MatchMessage) -> Bool {
        guard message.version == MatchMessage.protocolVersion else { return false }
        switch role {
        case .host:
            guard ready, message.kind == .input, message.matchID == matchID,
                  message.sequence > lastInput,
                  let y = message.paddleY, y.isFinite, (0...1).contains(y) else { return false }
            lastInput = message.sequence
            game.move(.right, to: y)
            displayed = game.snapshot
            return true
        case .guest:
            if message.kind == .welcome, !ready, matchID == nil,
               let state = message.state, Self.valid(state) {
                matchID = message.matchID
                displayed = state
                ready = true
                lastSnapshot = 0
                return true
            }
            guard ready, message.kind == .snapshot, message.matchID == matchID,
                  message.sequence > lastSnapshot,
                  let state = message.state, Self.valid(state) else { return false }
            lastSnapshot = message.sequence
            displayed = state
            return true
        case .solo, .idle: return false
        }
    }

    private static func valid(_ s: PongSnapshot) -> Bool {
        let values = [s.ballX, s.ballY, s.ballVX, s.ballVY,
                      s.leftPaddleY, s.rightPaddleY, s.serveRemaining]
        return values.allSatisfy { $0.isFinite && abs($0) <= 4 } &&
            (0...PongGame.winningScore).contains(s.leftScore) &&
            (0...PongGame.winningScore).contains(s.rightScore) &&
            (0...1).contains(s.leftPaddleY) &&
            (0...1).contains(s.rightPaddleY)
    }
}
