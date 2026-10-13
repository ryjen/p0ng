import Foundation
import XCTest
@testable import PongCore

/// Deterministic transport simulation for two real MatchCoordinators.
/// Packet delivery uses a logical clock; no sleeps or physical networking.
private struct SimulatedLink {
    enum Peer { case host, guest }
    struct Transit {
        let destination: Peer
        let packet: MatchMessage
        let due: Int
        let ordinal: Int
    }

    var host = MatchCoordinator()
    var guest = MatchCoordinator()
    var dropFirst: [String: Int]
    var dropRealtimeThird: Bool
    private(set) var frame = 0
    private(set) var droppedCount = 0
    private(set) var acceptedSnapshots = 0
    private var serial = 0
    private var realtimeCount = 0
    private var pending: [Transit] = []

    init(dropFirst: [String: Int] = [:], dropRealtimeThird: Bool = false) {
        self.dropFirst = dropFirst
        self.dropRealtimeThird = dropRealtimeThird
        host.startHosting()
        guest.startJoining()
    }

    mutating func send(_ outgoing: OutgoingMessage, from peer: Peer) {
        let kind = outgoing.packet.kind.rawValue
        if let remaining = dropFirst[kind], remaining > 0 {
            dropFirst[kind] = remaining - 1
            droppedCount += 1
            return
        }
        if outgoing.quality == .realtime {
            realtimeCount += 1
            if dropRealtimeThird && realtimeCount % 3 == 0 {
                droppedCount += 1
                return
            }
        }
        // Jitter reorder: odd snapshots arrive after newer even snapshots.
        let delay = outgoing.packet.kind == .snapshot &&
                    outgoing.quality == .realtime &&
                    !outgoing.packet.sequence.isMultiple(of: 2) ? 9 : 2
        serial += 1
        pending.append(Transit(destination: peer == .host ? .guest : .host,
                               packet: outgoing.packet, due: frame + delay,
                               ordinal: serial))
    }

    private mutating func deliver(_ entry: Transit) {
        switch entry.destination {
        case .host:
            let handshake = host.acceptHandshake(entry.packet)
            if handshake.accepted {
                if let response = handshake.response { send(response, from: .host) }
            } else {
                _ = host.receive(entry.packet)
            }
        case .guest:
            let handshake = guest.acceptHandshake(entry.packet)
            if handshake.accepted {
                if let response = handshake.response { send(response, from: .guest) }
            } else if guest.receive(entry.packet) {
                acceptedSnapshots += 1
            }
        }
    }

    mutating func advance(_ count: Int, simulateHost: Bool = true) {
        for _ in 0..<count {
            frame += 1
            if frame == 1 || frame % 60 == 0 {
                if let retry = guest.handshakeRetry() { send(retry, from: .guest) }
                if let retry = host.handshakeRetry() { send(retry, from: .host) }
            }
            if simulateHost, let snapshot = host.tick() {
                send(snapshot, from: .host)
            }
            let ready = pending.filter { $0.due <= frame }
                .sorted { a, b in a.due == b.due ?
                    a.ordinal < b.ordinal : a.due < b.due }
            pending.removeAll { $0.due <= frame }
            for entry in ready { deliver(entry) }
        }
    }

    mutating func restart() {
        host.disconnect()
        guest.disconnect()
        pending.removeAll()
        host.startHosting()
        guest.startJoining()
        frame = 0
    }
}

final class SimulatedNetworkTests: XCTestCase {
    func testFourLostHandshakeStagesRecoverWithoutEarlyHostTicks() {
        var link = SimulatedLink(dropFirst: [
            "welcome": 1, "ready": 1, "start": 1, "started": 1
        ])
        let initial = link.host.game.snapshot
        for _ in 0..<7 {
            link.advance(60)
            if !link.host.ready {
                XCTAssertEqual(link.host.game.snapshot, initial,
                               "Host must not advance before started ACK")
            }
        }
        XCTAssertTrue(link.host.ready)
        XCTAssertTrue(link.guest.ready)
        XCTAssertEqual(link.host.matchID, link.guest.matchID)
        XCTAssertEqual(link.droppedCount, 4)
        link.advance(40)
        XCTAssertGreaterThan(link.acceptedSnapshots, 0)
        XCTAssertNotEqual(link.host.game.snapshot, initial)
    }

    func testDroppedAndReorderedRealtimeSnapshotsPreserveScores() {
        var link = SimulatedLink(dropRealtimeThird: true)
        link.advance(720)
        XCTAssertTrue(link.host.ready)
        XCTAssertTrue(link.guest.ready)
        XCTAssertGreaterThan(link.acceptedSnapshots, 20)
        XCTAssertGreaterThan(link.droppedCount, 0)
        // Deliver all last packets without continuing the host simulation.
        link.advance(20, simulateHost: false)
        XCTAssertEqual(link.guest.displayed.leftScore, link.host.displayed.leftScore)
        XCTAssertEqual(link.guest.displayed.rightScore, link.host.displayed.rightScore)
        XCTAssertEqual(link.guest.displayed.phase, link.host.displayed.phase)
    }

    func testGuestInputIsDelayedButCannotForgeHostScore() {
        var link = SimulatedLink()
        link.advance(15)
        XCTAssertTrue(link.host.ready)
        XCTAssertTrue(link.guest.ready)
        let packet = link.guest.setPaddle(0.76, finished: true)!
        let old = link.host.game.snapshot.rightPaddleY
        link.send(packet, from: .guest)
        XCTAssertEqual(link.host.game.snapshot.rightPaddleY, old)
        link.advance(3)
        XCTAssertEqual(link.host.game.snapshot.rightPaddleY, 0.76, accuracy: 0.001)
        var forged = PongSnapshot()
        forged.leftScore = PongGame.winningScore
        XCTAssertFalse(link.host.receive(MatchMessage(
            kind: .snapshot, matchID: link.host.matchID!,
            sequence: 100, state: forged)))
        XCTAssertNotEqual(link.host.game.snapshot.leftScore, PongGame.winningScore)
    }

    func testPacketsFromPreviousSessionCannotMutateNewMatch() {
        var link = SimulatedLink()
        link.advance(15)
        XCTAssertTrue(link.host.ready)
        let oldID = link.host.matchID!
        link.restart()
        XCTAssertFalse(link.host.ready)
        XCTAssertFalse(link.guest.ready)
        let stale = MatchMessage(kind: .input, matchID: oldID,
                                 sequence: 999, paddleY: 0.83)
        XCTAssertFalse(link.host.receive(stale))
        link.advance(15)
        XCTAssertTrue(link.host.ready)
        XCTAssertTrue(link.guest.ready)
        XCTAssertNotEqual(link.host.matchID, oldID)
        XCTAssertFalse(link.host.receive(stale))
        XCTAssertFalse(link.guest.receive(MatchMessage(
            kind: .snapshot, matchID: oldID,
            sequence: 999, state: PongSnapshot())))
    }
}
