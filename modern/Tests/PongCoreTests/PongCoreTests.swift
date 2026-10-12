import XCTest
@testable import PongCore

final class PongCoreTests: XCTestCase {
    func testGuestCannotAuthoritativelyChangeBallOrScore() {
        var host = MatchCoordinator()
        var guest = MatchCoordinator()
        host.startHosting()
        guest.startJoining()
        let welcome = host.peerConnected(hello: MatchMessage(kind: .hello, matchID: UUID(), sequence: 0))!.packet
        XCTAssertTrue(guest.receive(welcome))
        let identifier = welcome.matchID
        var malicious = PongSnapshot()
        malicious.leftScore = 7
        XCTAssertFalse(host.receive(MatchMessage(kind: .snapshot, matchID: identifier,
                                                 sequence: 999, state: malicious)))
        XCTAssertEqual(host.displayed.leftScore, 0)
    }

    func testHostInputAndSnapshotReplication() {
        var host = MatchCoordinator()
        var guest = MatchCoordinator()
        host.startHosting()
        guest.startJoining()
        XCTAssertTrue(guest.receive(host.peerConnected(hello: MatchMessage(kind: .hello, matchID: UUID(), sequence: 0))!.packet))
        let input = guest.setPaddle(0.87)!
        XCTAssertTrue(host.receive(input.packet))
        XCTAssertEqual(host.displayed.rightPaddleY, 0.87, accuracy: 0.0001)
        XCTAssertFalse(host.receive(input.packet), "replayed input rejected")
        let snapshot = host.tick() ?? host.tick()!
        XCTAssertTrue(guest.receive(snapshot.packet))
        XCTAssertFalse(guest.receive(snapshot.packet), "replayed snapshot rejected")
        XCTAssertEqual(guest.displayed.rightPaddleY, host.displayed.rightPaddleY, accuracy: 0.0001)
    }

    func testInvalidValuesAndForeignMatchRejected() {
        var host = MatchCoordinator()
        host.startHosting()
        let id = host.peerConnected(hello: MatchMessage(kind: .hello, matchID: UUID(), sequence: 0))!.packet.matchID
        XCTAssertFalse(host.receive(MatchMessage(kind: .input, matchID: UUID(),
                                                sequence: 1, paddleY: 0.4)))
        XCTAssertFalse(host.receive(MatchMessage(kind: .input, matchID: id,
                                                sequence: 2, paddleY: .nan)))
        XCTAssertFalse(host.receive(MatchMessage(kind: .input, matchID: id,
                                                sequence: 3, paddleY: 10)))
        XCTAssertTrue(host.receive(MatchMessage(kind: .input, matchID: id,
                                               sequence: 1, paddleY: 0.4)))
        XCTAssertEqual(host.displayed.rightPaddleY, 0.4, accuracy: 0.0001)
    }

    func testGameScoringAndBounds() {
        var game = PongGame()
        game.move(.left, to: -10)
        game.move(.right, to: 10)
        XCTAssertEqual(game.snapshot.leftPaddleY, PongGame.paddleHeight / 2)
        XCTAssertEqual(game.snapshot.rightPaddleY, 1 - PongGame.paddleHeight / 2)
        for _ in 0..<60 * 30 { game.tick(1.0 / 60.0) }
        XCTAssertGreaterThan(game.snapshot.leftScore + game.snapshot.rightScore, 0)
        XCTAssertLessThanOrEqual(max(game.snapshot.leftScore, game.snapshot.rightScore), PongGame.winningScore)
    }

    func testPacketRoundTrip() throws {
        let message = MatchMessage(kind: .welcome, matchID: UUID(), sequence: 0,
                                   state: PongSnapshot())
        let data = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(MatchMessage.self, from: data), message)
    }

    func testVersionAndStaleWelcomeRejected() {
        var guest = MatchCoordinator()
        guest.startJoining()
        var welcome = MatchMessage(kind: .welcome, matchID: UUID(), sequence: 0,
                                   state: PongSnapshot())
        welcome.version = 999
        XCTAssertFalse(guest.receive(welcome))
        welcome.version = MatchMessage.protocolVersion
        XCTAssertTrue(guest.receive(welcome))
        XCTAssertFalse(guest.receive(welcome))
        guest.disconnect()
        XCTAssertFalse(guest.receive(welcome))
    }
}

extension PongCoreTests {
    func testHostRejectsGuestWelcomeAndStaleMatchAfterRestart() {
        var host = MatchCoordinator()
        host.startHosting()
        let first = host.peerConnected(hello: MatchMessage(kind: .hello, matchID: UUID(), sequence: 0))!.packet
        XCTAssertFalse(host.receive(first))
        host.disconnect()
        host.startHosting()
        let second = host.peerConnected(hello: MatchMessage(kind: .hello, matchID: UUID(), sequence: 0))!.packet
        XCTAssertNotEqual(first.matchID, second.matchID)
        XCTAssertFalse(host.receive(MatchMessage(kind: .input, matchID: first.matchID,
                                                sequence: 1, paddleY: 0.5)))
    }

    func testGuestCannotApplyMalformedSnapshot() {
        var guest = MatchCoordinator()
        guest.startJoining()
        let id = UUID()
        XCTAssertTrue(guest.receive(MatchMessage(kind: .welcome, matchID: id,
                                                 sequence: 0, state: PongSnapshot())))
        var bad = PongSnapshot()
        bad.ballY = .infinity
        XCTAssertFalse(guest.receive(MatchMessage(kind: .snapshot, matchID: id,
                                                  sequence: 1, state: bad)))
        XCTAssertTrue(guest.receive(MatchMessage(kind: .snapshot, matchID: id,
                                                 sequence: 1, state: PongSnapshot())))
    }

    func testSoloAndHostDoNotApplyGuestPhysics() {
        var solo = MatchCoordinator()
        solo.startSolo()
        XCTAssertNil(solo.peerConnected(hello: MatchMessage(kind: .hello, matchID: UUID(), sequence: 0)))
        for _ in 0..<100 { XCTAssertNil(solo.tick()) }
        XCTAssertEqual(solo.displayed.phase, .playing)
        var host = MatchCoordinator()
        host.startHosting()
        XCTAssertNil(host.tick(), "Host waits for connection")
    }
}

extension PongCoreTests {
    func testHandshakeRequiresGuestHello() {
        var host = MatchCoordinator()
        var guest = MatchCoordinator()
        host.startHosting()
        guest.startJoining()
        XCTAssertNil(host.peerConnected(hello: MatchMessage(kind: .snapshot,
                                                            matchID: UUID(), sequence: 0)))
        XCTAssertNil(host.tick(), "Host must not simulate before guest hello")
        let hello = guest.makeHello()!
        XCTAssertEqual(hello.packet.kind, .hello)
        XCTAssertEqual(hello.quality, .reliable)
        let welcome = host.peerConnected(hello: hello.packet)!.packet
        XCTAssertNil(host.peerConnected(hello: hello.packet), "Replay must not restart match")
        XCTAssertTrue(guest.receive(welcome))
        XCTAssertNil(guest.makeHello())
    }

    func testInvalidHelloDoesNotActivateHost() {
        var host = MatchCoordinator()
        host.startHosting()
        var hello = MatchMessage(kind: .hello, matchID: UUID(), sequence: 0)
        hello.version = 999
        XCTAssertNil(host.peerConnected(hello: hello))
        hello.version = MatchMessage.protocolVersion
        hello.paddleY = 0.5
        XCTAssertNil(host.peerConnected(hello: hello))
        XCTAssertFalse(host.ready)
    }
}
