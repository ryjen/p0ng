import Foundation

/// Accumulates elapsed display time into deterministic host physics ticks.
/// A long foreground stall is discarded beyond a bounded catch-up budget.
public struct FrameStepper {
    public static let step = 1.0 / 60.0
    public private(set) var accumulator = 0.0
    public private(set) var discardedSeconds = 0.0

    public init() {}

    public mutating func reset() {
        accumulator = 0
        discardedSeconds = 0
    }

    public mutating func advance(elapsed: Double) -> Int {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        let bounded = min(elapsed, 0.1)
        discardedSeconds += max(0, elapsed - bounded)
        accumulator += bounded
        let available = Int((accumulator + 1e-9) / Self.step)
        let ticks = min(available, 6)
        accumulator -= Double(ticks) * Self.step
        // Never build an unbounded backlog under persistent overload.
        if accumulator >= Self.step {
            discardedSeconds += accumulator - accumulator.truncatingRemainder(dividingBy: Self.step)
            accumulator.formTruncatingRemainder(dividingBy: Self.step)
        }
        return ticks
    }
}

/// Coalesces finger movement to one latest-value input each 1/30s.
/// Final drag release bypasses the rate limit using a reliable packet.
public struct PaddleInputQueue {
    private var pending: Double?
    private var releasePending = false
    private var lastSendTime: Double?
    public init() {}

    public mutating func reset() {
        pending = nil
        releasePending = false
        lastSendTime = nil
    }

    public mutating func offer(y: Double, finished: Bool) {
        guard y.isFinite else { return }
        pending = min(1, max(0, y))
        releasePending = releasePending || finished
    }

    public mutating func take(at time: Double) -> (y: Double, finished: Bool)? {
        guard time.isFinite, let pending else { return nil }
        if !releasePending, let lastSendTime, time - lastSendTime < (1.0 / 30.0) {
            return nil
        }
        let result = (y: pending, finished: releasePending)
        self.pending = nil
        releasePending = false
        lastSendTime = time
        return result
    }
}

/// Render-only smoothing. The host's simulation and collision decisions never
/// consult interpolated coordinates. State transitions and scores never blend.
public struct SnapshotInterpolator {
    private struct Sample {
        var snapshot: PongSnapshot
        var receivedAt: Double
    }
    private var history: [Sample] = []
    public let delay: Double

    public init(delay: Double = 2.0 / 30.0) {
        self.delay = max(0, delay)
    }

    public mutating func reset() { history.removeAll(keepingCapacity: true) }

    public mutating func append(_ snapshot: PongSnapshot, at now: Double) {
        guard now.isFinite else { return }
        if let last = history.last {
            guard now >= last.receivedAt else { return }
            // Never interpolate through a serve, score, or game-over transition.
            if snapshot.phase != last.snapshot.phase ||
               snapshot.leftScore != last.snapshot.leftScore ||
               snapshot.rightScore != last.snapshot.rightScore {
                reset()
            }
        }
        history.append(Sample(snapshot: snapshot, receivedAt: now))
        if history.count > 8 { history.removeFirst(history.count - 8) }
    }

    public func sample(at now: Double) -> PongSnapshot? {
        guard let first = history.first else { return nil }
        guard now.isFinite else { return history.last?.snapshot }
        let target = now - delay
        if target <= first.receivedAt { return first.snapshot }
        guard let last = history.last, target < last.receivedAt else {
            return history.last?.snapshot
        }
        for index in 1..<history.count {
            let b = history[index]
            if target <= b.receivedAt {
                let a = history[index - 1]
                let span = b.receivedAt - a.receivedAt
                let f = span > 0 ? min(1, max(0, (target - a.receivedAt) / span)) : 1
                var s = b.snapshot
                func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
                s.ballX = blend(a.snapshot.ballX, b.snapshot.ballX)
                s.ballY = blend(a.snapshot.ballY, b.snapshot.ballY)
                s.leftPaddleY = blend(a.snapshot.leftPaddleY, b.snapshot.leftPaddleY)
                s.rightPaddleY = blend(a.snapshot.rightPaddleY, b.snapshot.rightPaddleY)
                s.serveRemaining = blend(a.snapshot.serveRemaining, b.snapshot.serveRemaining)
                return s
            }
        }
        return history.last?.snapshot
    }
}

/// Fast local finger feedback without permanently hiding the authoritative
/// paddle after finger-up. When corrections are needed, they ease in rather
/// than teleporting the user's paddle. This affects rendering only.
public struct PaddleReconciliation {
    private var desiredY: Double?
    private var releasedAt: Double?
    public init() {}

    public mutating func reset() {
        desiredY = nil
        releasedAt = nil
    }

    public mutating func update(y: Double, finished: Bool, at now: Double) {
        guard y.isFinite, now.isFinite else { return }
        desiredY = min(1, max(0, y))
        releasedAt = finished ? now : nil
    }

    public mutating func render(authoritative: Double, at now: Double) -> Double {
        guard let desiredY else { return authoritative }
        guard let releasedAt else { return desiredY }
        guard now.isFinite else { return desiredY }

        let elapsed = max(0, now - releasedAt)
        // Hold for two to three snapshots before beginning correction.
        let factor = min(1, max(0, (elapsed - 0.15) / 0.35))
        let blended = desiredY + (authoritative - desiredY) * factor
        if factor >= 1 || (elapsed >= 0.15 && abs(desiredY - authoritative) < 0.001) {
            self.desiredY = nil
            self.releasedAt = nil
            return authoritative
        }
        return blended
    }
}

/// Flushes only the newest replaceable snapshot per rendering frame while
/// preserving reliable score and phase transitions produced during catch-up.
/// The host remains authoritative; this is purely transport backpressure.
public struct SnapshotPacketBatch {
    private var critical: [OutgoingMessage] = []
    private var latestRealtime: OutgoingMessage?

    public init() {}

    public mutating func append(_ packet: OutgoingMessage) {
        switch packet.quality {
        case .reliable:
            critical.append(packet)
        case .realtime:
            latestRealtime = packet
        }
    }

    public mutating func drain() -> [OutgoingMessage] {
        var result = critical
        if let latestRealtime { result.append(latestRealtime) }
        critical.removeAll(keepingCapacity: true)
        latestRealtime = nil
        return result
    }
}

/// Bounds packet decoding work on the delegate queue. The window applies to
/// received packets, regardless of their validity, and is reset per session.
public struct PacketIngressWindow {
    public let maxPerSecond: Int
    private var startTime: Double?
    private var accepted = 0

    public init(maxPerSecond: Int = 120) {
        self.maxPerSecond = max(1, maxPerSecond)
    }

    public mutating func reset() {
        startTime = nil
        accepted = 0
    }

    public mutating func admit(at now: Double) -> Bool {
        guard now.isFinite else { return false }
        if let startTime {
            if now < startTime || now - startTime >= 1.0 { reset() }
        }
        if startTime == nil { startTime = now }
        guard accepted < maxPerSecond else { return false }
        accepted += 1
        return true
    }
}
