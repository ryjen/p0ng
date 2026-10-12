import Foundation

/// World coordinates are normalized into [0, 1] independent of the device's pixel size.
public enum PlayerSide: String, Codable, Equatable, Sendable {
    case left, right
}

public enum RoundPhase: String, Codable, Equatable, Sendable {
    case serving, playing, finished
}

public struct PongSnapshot: Codable, Equatable, Sendable {
    public var ballX: Double = 0.5
    public var ballY: Double = 0.5
    public var ballVX: Double = 0.62
    public var ballVY: Double = 0.24
    public var leftPaddleY: Double = 0.5
    public var rightPaddleY: Double = 0.5
    public var leftScore: Int = 0
    public var rightScore: Int = 0
    public var phase: RoundPhase = .serving
    public var serveRemaining: Double = 1.0

    public init() {}
}

public struct PongGame {
    public static let paddleHeight = 0.20
    public static let paddleWidth = 0.018
    public static let paddleInset = 0.055
    public static let ballRadius = 0.012
    public static let winningScore = 7

    public private(set) var snapshot = PongSnapshot()
    private var serveDirection = 1.0

    public init() {}

    public mutating func move(_ side: PlayerSide, to y: Double) {
        guard y.isFinite else { return }
        let position = min(1 - Self.paddleHeight / 2,
                           max(Self.paddleHeight / 2, y))
        switch side {
        case .left: snapshot.leftPaddleY = position
        case .right: snapshot.rightPaddleY = position
        }
    }

    public mutating func tick(_ seconds: Double, againstComputer: Bool = false) {
        guard seconds.isFinite, seconds > 0, seconds <= 0.05,
              snapshot.phase != .finished else { return }
        if againstComputer {
            let target = snapshot.ballVX > 0 ? snapshot.ballY : 0.5
            let delta = min(0.72 * seconds,
                            abs(target - snapshot.rightPaddleY))
            let next = snapshot.rightPaddleY + (target < snapshot.rightPaddleY ? -delta : delta)
            move(.right, to: next)
        }
        if snapshot.phase == .serving {
            snapshot.serveRemaining = max(0, snapshot.serveRemaining - seconds)
            if snapshot.serveRemaining == 0 { snapshot.phase = .playing }
            return
        }

        let oldX = snapshot.ballX
        snapshot.ballX += snapshot.ballVX * seconds
        snapshot.ballY += snapshot.ballVY * seconds

        if snapshot.ballY < Self.ballRadius {
            snapshot.ballY = 2 * Self.ballRadius - snapshot.ballY
            snapshot.ballVY = abs(snapshot.ballVY)
        } else if snapshot.ballY > 1 - Self.ballRadius {
            snapshot.ballY = 2 * (1 - Self.ballRadius) - snapshot.ballY
            snapshot.ballVY = -abs(snapshot.ballVY)
        }

        let leftFace = Self.paddleInset + Self.paddleWidth / 2 + Self.ballRadius
        let rightFace = 1 - leftFace
        if snapshot.ballVX < 0, oldX >= leftFace, snapshot.ballX <= leftFace,
           abs(snapshot.ballY - snapshot.leftPaddleY) <= Self.paddleHeight / 2 + Self.ballRadius {
            bounce(off: .left, at: leftFace)
        } else if snapshot.ballVX > 0, oldX <= rightFace, snapshot.ballX >= rightFace,
                  abs(snapshot.ballY - snapshot.rightPaddleY) <= Self.paddleHeight / 2 + Self.ballRadius {
            bounce(off: .right, at: rightFace)
        }

        if snapshot.ballX < -Self.ballRadius {
            point(to: .right)
        } else if snapshot.ballX > 1 + Self.ballRadius {
            point(to: .left)
        }
    }

    private mutating func bounce(off side: PlayerSide, at face: Double) {
        let paddle = side == .left ? snapshot.leftPaddleY : snapshot.rightPaddleY
        let impact = max(-1, min(1, (snapshot.ballY - paddle) / (Self.paddleHeight / 2)))
        let angle = impact * (.pi / 3)
        let speed = min(1.30, hypot(snapshot.ballVX, snapshot.ballVY) * 1.04)
        let direction = side == .left ? 1.0 : -1.0
        snapshot.ballX = face
        snapshot.ballVX = direction * speed * cos(angle)
        snapshot.ballVY = speed * sin(angle)
    }

    private mutating func point(to side: PlayerSide) {
        if side == .left { snapshot.leftScore += 1 }
        else { snapshot.rightScore += 1 }
        if max(snapshot.leftScore, snapshot.rightScore) >= Self.winningScore {
            snapshot.phase = .finished
            snapshot.ballVX = 0
            snapshot.ballVY = 0
            return
        }
        serveDirection = side == .left ? 1.0 : -1.0
        snapshot.ballX = 0.5
        snapshot.ballY = 0.5
        snapshot.ballVX = 0.62 * serveDirection
        snapshot.ballVY = 0.24 * (side == .left ? 1 : -1)
        snapshot.phase = .serving
        snapshot.serveRemaining = 1
    }
}
