import XCTest
@testable import PongCore

final class PongCoreTests: XCTestCase {
    /// Complete a simulated, reliable five-message setup without a network stack.
    @discardableResult
    private func connect(_ host: inout MatchCoordinator,
                         _ guest: inout MatchCoordinator) -> UUID {
        host.startHosting()
        guest.startJoining()
        let hello = guest.handshakeRetry()!
        XCTAssertEqual(hello.packet.kind, .hello)
        let welcome = host.acceptHandshake(hello.packet)
        XCTAssertTrue(welcome.accepted)
        XCTAssertEqual(welcome.response?.packet.kind, .welcome)
        let prepared = guest.acceptHandshake(welcome.response!.packet)
        XCTAssertTrue(prepared.accepted)
        XCTAssertEqual(prepared.response?.packet.kind, .ready)
        XCTAssertFalse(host.ready, "Host must remain stopped after welcome")
        XCTAssertFalse(guest.ready, "Guest must remain stopped before start")
        let start = host.acceptHandshake(prepared.response!.packet)
        XCTAssertTrue(start.accepted)
        XCTAssertEqual(start.response?.packet.kind, .start)
        XCTAssertFalse(host.ready, "Sending start alone does not activate host")
        let started = guest.acceptHandshake(start.response!.packet)
        XCTAssertTrue(started.accepted)
        XCTAssertEqual(started.response?.packet.kind, .started)
        XCTAssertTrue(guest.ready)
        XCTAssertFalse(host.ready, "Wait for acknowledgement from guest")
        let acknowledged = host.acceptHandshake(started.response!.packet)
        XCTAssertTrue(acknowledged.accepted)
        XCTAssertNil(acknowledged.response)
        XCTAssertTrue(host.ready)
        return host.matchID!
    }

    func testStartBarrierBlocksHostAndGuestSimulation() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        host.startHosting()
        guest.startJoining()
        XCTAssertNil(host.tick())
        XCTAssertNil(guest.setPaddle(0.7))
        let welcome = host.acceptHandshake(guest.handshakeRetry()!.packet).response!.packet
        let ready = guest.acceptHandshake(welcome).response!.packet
        XCTAssertFalse(host.ready)
        XCTAssertFalse(guest.ready)
        XCTAssertNil(host.tick())
        XCTAssertNil(guest.setPaddle(0.7))
        let start = host.acceptHandshake(ready).response!.packet
        XCTAssertNil(host.tick(), "Host must wait for guest's final acknowledgement")
        let started = guest.acceptHandshake(start).response!.packet
        XCTAssertNil(host.tick(), "Guest starting is not evidence that ack was received")
        XCTAssertTrue(host.acceptHandshake(started).accepted)
        XCTAssertNotNil(host.tick() ?? host.tick())
    }

    func testHandshakeRetriesAreIdempotent() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        host.startHosting()
        guest.startJoining()
        let hello = guest.handshakeRetry()!.packet
        let welcome = host.acceptHandshake(hello).response!.packet
        XCTAssertEqual(host.handshakeRetry()?.packet, welcome)
        XCTAssertEqual(host.acceptHandshake(hello).response?.packet, welcome)
        let ready = guest.acceptHandshake(welcome).response!.packet
        XCTAssertEqual(guest.handshakeRetry()?.packet, ready)
        XCTAssertEqual(guest.acceptHandshake(welcome).response?.packet, ready)
        let start = host.acceptHandshake(ready).response!.packet
        XCTAssertEqual(host.handshakeRetry()?.packet, start)
        XCTAssertEqual(host.acceptHandshake(ready).response?.packet, start)
        let started = guest.acceptHandshake(start).response!.packet
        XCTAssertTrue(guest.ready)
        XCTAssertEqual(guest.acceptHandshake(start).response?.packet, started,
                       "Lost acknowledgement must be recoverable with repeated start")
        XCTAssertTrue(host.acceptHandshake(started).accepted)
        XCTAssertTrue(host.ready)
        XCTAssertNil(host.handshakeRetry())
        XCTAssertNil(guest.handshakeRetry())
        XCTAssertTrue(host.acceptHandshake(started).accepted, "Repeated ack is harmless")
    }

    func testLostWelcomeReadyAndStartRecoverByRetry() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        host.startHosting()
        guest.startJoining()
        let hello = guest.handshakeRetry()!.packet
        _ = host.acceptHandshake(hello) // Drop initial welcome
        XCTAssertNil(host.tick())
        let welcome = host.handshakeRetry()!.packet
        _ = guest.acceptHandshake(welcome) // Drop guest's initial ready
        let ready = guest.handshakeRetry()!.packet
        _ = host.acceptHandshake(ready) // Drop initial start
        XCTAssertFalse(host.ready)
        let start = host.handshakeRetry()!.packet
        let started = guest.acceptHandshake(start).response!.packet
        _ = host.acceptHandshake(started)
        XCTAssertTrue(host.ready)
        XCTAssertTrue(guest.ready)
    }

    func testHostRejectsPrematureAndForeignAcknowledgements() {
        var host = MatchCoordinator()
        host.startHosting()
        let id = host.matchID!
        XCTAssertFalse(host.acceptHandshake(MatchMessage(kind: .ready, matchID: id,
                                                         sequence: 0)).accepted)
        XCTAssertFalse(host.acceptHandshake(MatchMessage(kind: .started, matchID: id,
                                                         sequence: 0)).accepted)
        let hello = MatchMessage(kind: .hello, matchID: UUID(), sequence: 0)
        XCTAssertTrue(host.acceptHandshake(hello).accepted)
        XCTAssertFalse(host.acceptHandshake(MatchMessage(kind: .ready, matchID: UUID(),
                                                         sequence: 0)).accepted)
        XCTAssertTrue(host.acceptHandshake(MatchMessage(kind: .ready, matchID: id,
                                                        sequence: 0)).accepted)
        XCTAssertFalse(host.acceptHandshake(MatchMessage(kind: .started, matchID: UUID(),
                                                         sequence: 0)).accepted)
        XCTAssertFalse(host.ready)
        XCTAssertTrue(host.acceptHandshake(MatchMessage(kind: .started, matchID: id,
                                                        sequence: 0)).accepted)
        XCTAssertTrue(host.ready)
    }

    func testMalformedHandshakeMessagesRejected() {
        var host = MatchCoordinator()
        host.startHosting()
        var hello = MatchMessage(kind: .hello, matchID: UUID(), sequence: 0)
        hello.version = 1
        XCTAssertFalse(host.acceptHandshake(hello).accepted)
        hello.version = MatchMessage.protocolVersion
        hello.sequence = 1
        XCTAssertFalse(host.acceptHandshake(hello).accepted)
        hello.sequence = 0
        hello.paddleY = 0.5
        XCTAssertFalse(host.acceptHandshake(hello).accepted)
        hello.paddleY = nil
        hello.state = PongSnapshot()
        XCTAssertFalse(host.acceptHandshake(hello).accepted)
        hello.state = nil
        XCTAssertTrue(host.acceptHandshake(hello).accepted)

        var guest = MatchCoordinator()
        guest.startJoining()
        var bad = PongSnapshot()
        bad.ballY = .infinity
        let id = host.matchID!
        XCTAssertFalse(guest.acceptHandshake(MatchMessage(kind: .welcome, matchID: id,
                                                           sequence: 0, state: bad)).accepted)
        XCTAssertFalse(guest.acceptHandshake(MatchMessage(kind: .welcome, matchID: id,
                                                           sequence: 0, paddleY: 0.5,
                                                           state: PongSnapshot())).accepted)
        XCTAssertTrue(guest.acceptHandshake(MatchMessage(kind: .welcome, matchID: id,
                                                          sequence: 0,
                                                          state: PongSnapshot())).accepted)
        XCTAssertFalse(guest.acceptHandshake(MatchMessage(kind: .start, matchID: UUID(),
                                                           sequence: 0)).accepted)
        XCTAssertFalse(guest.ready)
    }

    func testDisconnectResetsBothHandshakeStates() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        host.startHosting()
        guest.startJoining()
        let welcome = host.acceptHandshake(guest.handshakeRetry()!.packet).response!.packet
        _ = guest.acceptHandshake(welcome)
        host.disconnect()
        guest.disconnect()
        XCTAssertNil(host.handshakeRetry())
        XCTAssertNil(guest.handshakeRetry())
        XCTAssertFalse(host.acceptHandshake(MatchMessage(kind: .ready,
                                                         matchID: welcome.matchID,
                                                         sequence: 0)).accepted)
        XCTAssertFalse(guest.acceptHandshake(welcome).accepted)
        host.startHosting()
        XCTAssertNotEqual(host.matchID, welcome.matchID)
    }

    func testGuestCannotAuthoritativelyChangeBallOrScore() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        let id = connect(&host, &guest)
        var malicious = PongSnapshot()
        malicious.leftScore = 7
        XCTAssertFalse(host.receive(MatchMessage(kind: .snapshot, matchID: id,
                                                 sequence: 999, state: malicious)))
        XCTAssertEqual(host.displayed.leftScore, 0)
    }

    func testHostInputAndSnapshotReplication() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        connect(&host, &guest)
        let input = guest.setPaddle(0.87)!
        XCTAssertTrue(host.receive(input.packet))
        XCTAssertEqual(host.displayed.rightPaddleY, 0.87, accuracy: 0.0001)
        XCTAssertFalse(host.receive(input.packet), "Replayed input must be rejected")
        let snapshot = host.tick() ?? host.tick()!
        XCTAssertTrue(guest.receive(snapshot.packet))
        XCTAssertFalse(guest.receive(snapshot.packet), "Replayed snapshot must be rejected")
        XCTAssertEqual(guest.displayed.rightPaddleY, host.displayed.rightPaddleY, accuracy: 0.0001)
    }

    func testInputsAndSnapshotsRejectedBeforeMatchReady() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        host.startHosting()
        guest.startJoining()
        let welcome = host.acceptHandshake(guest.handshakeRetry()!.packet).response!.packet
        XCTAssertFalse(host.receive(MatchMessage(kind: .input, matchID: welcome.matchID,
                                                 sequence: 1, paddleY: 0.8)))
        XCTAssertFalse(guest.receive(MatchMessage(kind: .snapshot, matchID: welcome.matchID,
                                                  sequence: 1, state: PongSnapshot())))
        _ = guest.acceptHandshake(welcome)
        XCTAssertFalse(guest.ready)
    }

    func testInvalidValuesAndForeignMatchRejected() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        let id = connect(&host, &guest)
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
        XCTAssertLessThanOrEqual(max(game.snapshot.leftScore, game.snapshot.rightScore),
                                 PongGame.winningScore)
    }

    func testPacketRoundTrip() throws {
        let message = MatchMessage(kind: .welcome, matchID: UUID(), sequence: 0,
                                   state: PongSnapshot())
        let data = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(MatchMessage.self, from: data), message)
        XCTAssertEqual(MatchMessage.protocolVersion, 2)
    }

    func testHostRejectsGuestWelcomeAndStaleMatchAfterRestart() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        let first = connect(&host, &guest)
        XCTAssertFalse(host.acceptHandshake(MatchMessage(kind: .welcome,
                                                         matchID: first, sequence: 0,
                                                         state: PongSnapshot())).accepted)
        host.disconnect()
        var next = MatchCoordinator()
        connect(&host, &next)
        XCTAssertNotEqual(first, host.matchID)
        XCTAssertFalse(host.receive(MatchMessage(kind: .input, matchID: first,
                                                 sequence: 1, paddleY: 0.5)))
    }

    func testGuestCannotApplyMalformedSnapshot() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        let id = connect(&host, &guest)
        var bad = PongSnapshot()
        bad.ballY = .infinity
        XCTAssertFalse(guest.receive(MatchMessage(kind: .snapshot, matchID: id,
                                                  sequence: 1, state: bad)))
        XCTAssertTrue(guest.receive(MatchMessage(kind: .snapshot, matchID: id,
                                                 sequence: 1, state: PongSnapshot())))
    }

    func testGuestRejectsInvalidServeCountdownDuringHandshakeAndPlay() {
        let matchID = UUID()
        var joining = MatchCoordinator()
        joining.startJoining()

        var invalid = PongSnapshot()
        invalid.serveRemaining = -PongGame.serveDurationSeconds
        XCTAssertFalse(joining.acceptHandshake(MatchMessage(
            kind: .welcome, matchID: matchID, sequence: 0, state: invalid)).accepted)
        XCTAssertNil(joining.matchID, "Invalid welcome cannot bind a match")

        invalid.serveRemaining = PongGame.serveDurationSeconds.nextUp
        XCTAssertFalse(joining.acceptHandshake(MatchMessage(
            kind: .welcome, matchID: matchID, sequence: 0, state: invalid)).accepted)
        XCTAssertNil(joining.matchID)

        let validWelcome = MatchMessage(
            kind: .welcome, matchID: matchID, sequence: 0, state: PongSnapshot())
        XCTAssertTrue(joining.acceptHandshake(validWelcome).accepted)

        var host = MatchCoordinator(), guest = MatchCoordinator()
        let id = connect(&host, &guest)
        let previous = guest.displayed
        for countdown in [-PongGame.serveDurationSeconds,
                          PongGame.serveDurationSeconds.nextUp] {
            var snapshot = PongSnapshot()
            snapshot.serveRemaining = countdown
            XCTAssertFalse(guest.receive(MatchMessage(
                kind: .snapshot, matchID: id, sequence: 1, state: snapshot)))
            XCTAssertEqual(guest.displayed, previous,
                           "Invalid snapshot must not change render state")
        }
        XCTAssertTrue(guest.receive(MatchMessage(
            kind: .snapshot, matchID: id, sequence: 1, state: PongSnapshot())),
            "Rejected packets must not consume sequence numbers")
    }

    func testGuestRejectsScoreRegressionWithoutConsumingSequence() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        let id = connect(&host, &guest)
        var initial = PongSnapshot()
        initial.leftScore = 2
        initial.rightScore = 1
        initial.phase = .playing
        initial.serveRemaining = 0
        XCTAssertTrue(guest.receive(MatchMessage(
            kind: .snapshot, matchID: id, sequence: 1, state: initial)))

        var regressed = initial
        regressed.leftScore = 1
        XCTAssertFalse(guest.receive(MatchMessage(
            kind: .snapshot, matchID: id, sequence: 2, state: regressed)))
        XCTAssertEqual(guest.displayed, initial)

        regressed = initial
        regressed.rightScore = 0
        XCTAssertFalse(guest.receive(MatchMessage(
            kind: .snapshot, matchID: id, sequence: 2, state: regressed)))
        XCTAssertEqual(guest.displayed, initial)

        var next = initial
        next.rightScore = 2
        XCTAssertTrue(guest.receive(MatchMessage(
            kind: .snapshot, matchID: id, sequence: 2, state: next)),
            "Rejected rollback must not consume the next valid sequence")
        XCTAssertEqual(guest.displayed, next)
    }

    func testGuestCannotReopenOrUpdateFinishedMatch() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        let id = connect(&host, &guest)
        var winner = PongSnapshot()
        winner.leftScore = PongGame.winningScore
        winner.phase = .finished
        winner.serveRemaining = 0
        winner.ballVX = 0
        winner.ballVY = 0
        XCTAssertTrue(guest.receive(MatchMessage(
            kind: .snapshot, matchID: id, sequence: 1, state: winner)))

        var reopening = PongSnapshot()
        reopening.leftScore = PongGame.winningScore - 1
        reopening.phase = .playing
        reopening.serveRemaining = 0
        XCTAssertFalse(guest.receive(MatchMessage(
            kind: .snapshot, matchID: id, sequence: 2, state: reopening)))
        XCTAssertFalse(guest.receive(MatchMessage(
            kind: .snapshot, matchID: id, sequence: 3, state: winner)),
            "Even a later terminal snapshot cannot mutate a completed match")
        XCTAssertEqual(guest.displayed, winner)
        XCTAssertTrue(guest.ready, "Completed match remains ready until reset or disconnect")
    }

    func testGuestRejectsImpossibleScoreAndPhaseWithoutAdvancingSequence() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        let id = connect(&host, &guest)
        let previous = guest.displayed

        var unfinishedWinner = PongSnapshot()
        unfinishedWinner.leftScore = PongGame.winningScore
        unfinishedWinner.phase = .playing

        var servingWinner = PongSnapshot()
        servingWinner.rightScore = PongGame.winningScore
        servingWinner.phase = .serving

        var scorelessFinish = PongSnapshot()
        scorelessFinish.phase = .finished
        scorelessFinish.serveRemaining = 0

        var doubleWinner = scorelessFinish
        doubleWinner.leftScore = PongGame.winningScore
        doubleWinner.rightScore = PongGame.winningScore

        // Invalid packets must not consume the authoritative sequence slot.
        for impossible in [unfinishedWinner, servingWinner, scorelessFinish, doubleWinner] {
            XCTAssertFalse(guest.receive(MatchMessage(
                kind: .snapshot, matchID: id, sequence: 1, state: impossible)))
            XCTAssertEqual(guest.displayed, previous)
        }

        var validFinish = scorelessFinish
        validFinish.leftScore = PongGame.winningScore
        XCTAssertTrue(guest.receive(MatchMessage(
            kind: .snapshot, matchID: id, sequence: 1, state: validFinish)))
        XCTAssertEqual(guest.displayed.phase, .finished)
        XCTAssertEqual(guest.displayed.leftScore, PongGame.winningScore)
    }

    func testInvalidFinishedWelcomeCannotBindGuestMatch() {
        let id = UUID()
        var guest = MatchCoordinator()
        guest.startJoining()
        var invalid = PongSnapshot()
        invalid.phase = .finished
        invalid.serveRemaining = 0

        XCTAssertFalse(guest.acceptHandshake(MatchMessage(
            kind: .welcome, matchID: id, sequence: 0, state: invalid)).accepted)
        XCTAssertNil(guest.matchID)
        XCTAssertFalse(guest.ready)

        XCTAssertTrue(guest.acceptHandshake(MatchMessage(
            kind: .welcome, matchID: id, sequence: 0, state: PongSnapshot())).accepted)
        XCTAssertEqual(guest.matchID, id)
    }

    func testSoloAndHostDoNotApplyGuestPhysics() {
        var solo = MatchCoordinator()
        solo.startSolo()
        XCTAssertFalse(solo.acceptHandshake(MatchMessage(kind: .hello, matchID: UUID(),
                                                          sequence: 0)).accepted)
        for _ in 0..<100 { XCTAssertNil(solo.tick()) }
        XCTAssertEqual(solo.displayed.phase, .playing)
        var host = MatchCoordinator()
        host.startHosting()
        XCTAssertNil(host.tick(), "Host waits for acknowledged start")
    }

    func testHostStopsSnapshotsAndRejectsInputAfterFinish() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        let id = connect(&host, &guest)
        for _ in 0..<(60 * 300) {
            if host.displayed.phase == .finished { break }
            _ = host.tick()
        }
        XCTAssertEqual(host.displayed.phase, .finished)
        XCTAssertNil(host.tick(), "No post-game snapshots")
        XCTAssertFalse(host.receive(MatchMessage(kind: .input, matchID: id,
                                                 sequence: 1, paddleY: 0.8)))
    }

    func testUnexpectedPacketFieldsAreRejected() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        let id = connect(&host, &guest)
        XCTAssertFalse(host.receive(MatchMessage(kind: .input, matchID: id,
                                                 sequence: 1, paddleY: 0.5,
                                                 state: PongSnapshot())))
        XCTAssertTrue(host.receive(MatchMessage(kind: .input, matchID: id,
                                                sequence: 1, paddleY: 0.5)))
        XCTAssertFalse(guest.receive(MatchMessage(kind: .snapshot, matchID: id,
                                                  sequence: 1, paddleY: 0.5,
                                                  state: PongSnapshot())))
        XCTAssertTrue(guest.receive(MatchMessage(kind: .snapshot, matchID: id,
                                                 sequence: 1, state: PongSnapshot())))
    }

    func testSameInputsProduceSamePhysics() {
        var first = PongGame(), second = PongGame()
        for i in 0..<3000 {
            let y = Double((i * 7) % 100) / 100
            first.move(.left, to: y)
            second.move(.left, to: y)
            first.tick(1.0 / 60.0, againstComputer: true)
            second.tick(1.0 / 60.0, againstComputer: true)
        }
        XCTAssertEqual(first.snapshot, second.snapshot)
    }
}

extension PongCoreTests {
    func testAdmissionAllowsOnlyOnePendingOrAcceptedInvitation() {
        var gate = NearbyAdmissionGate()
        XCTAssertTrue(gate.offer())
        XCTAssertFalse(gate.offer(), "Second invitation must be rejected while alert is open")
        XCTAssertTrue(gate.resolve(accept: true))
        XCTAssertFalse(gate.resolve(accept: true), "Decision is idempotent")
        XCTAssertFalse(gate.offer(), "Do not admit a second peer before the first connects")
        XCTAssertTrue(gate.didConnect())
        XCTAssertFalse(gate.offer(), "Do not admit a third peer in an active match")
        XCTAssertTrue(gate.didConnect(), "Duplicate connected callbacks are harmless")
        gate.reset()
        XCTAssertTrue(gate.offer(), "New hosting session can accept a player")
    }

    func testRejectedOrAbortedInvitationAllowsRetry() {
        var gate = NearbyAdmissionGate()
        XCTAssertFalse(gate.resolve(accept: true))
        XCTAssertTrue(gate.offer())
        XCTAssertTrue(gate.resolve(accept: false))
        XCTAssertTrue(gate.offer(), "Rejected invitation releases the slot")
        XCTAssertTrue(gate.resolve(accept: true))
        gate.reset() // Failed session before connection
        XCTAssertTrue(gate.offer())
    }

    func testAdmissionCannotConnectWithoutAcceptance() {
        var gate = NearbyAdmissionGate()
        XCTAssertFalse(gate.didConnect())
        XCTAssertTrue(gate.offer())
        XCTAssertFalse(gate.didConnect(), "Pending approval is not an accepted connection")
        XCTAssertEqual(gate.state, .pending)
    }
}

extension PongCoreTests {
    func testFrameStepperCatchesUpAndCapsBackgroundStalls() {
        var clock = FrameStepper()
        XCTAssertEqual(clock.advance(elapsed: 1.0 / 60.0), 1)
        XCTAssertEqual(clock.advance(elapsed: 1.0 / 30.0), 2)
        XCTAssertEqual(clock.advance(elapsed: 0), 0)
        XCTAssertEqual(clock.advance(elapsed: .nan), 0)
        XCTAssertEqual(clock.advance(elapsed: 10), 6, "Do not simulate 10 seconds in one frame")
        XCTAssertGreaterThan(clock.discardedSeconds, 9)
        clock.reset()
        XCTAssertEqual(clock.discardedSeconds, 0)
        XCTAssertEqual(clock.advance(elapsed: 1.0 / 60.0), 1)
    }

    func testInputQueueCoalescesAndReleasesReliably() {
        var queue = PaddleInputQueue()
        queue.offer(y: 0.2, finished: false)
        queue.offer(y: 0.8, finished: false)
        XCTAssertEqual(queue.take(at: 1)!.y, 0.8, accuracy: 0.001)
        XCTAssertNil(queue.take(at: 1.01))
        queue.offer(y: 0.3, finished: false)
        XCTAssertNil(queue.take(at: 1.02))
        queue.offer(y: 0.4, finished: true)
        let final = queue.take(at: 1.021)
        XCTAssertEqual(final?.y, 0.4)
        XCTAssertEqual(final?.finished, true)
        XCTAssertNil(queue.take(at: 1.1))
    }

    func testRenderOnlyInterpolationDoesNotBlendScores() {
        var buffer = SnapshotInterpolator(delay: 0.02)
        var a = PongSnapshot()
        a.phase = .playing
        a.ballX = 0.1
        var b = a
        b.ballX = 0.5
        buffer.append(a, at: 1.0)
        buffer.append(b, at: 1.1)
        XCTAssertEqual(buffer.sample(at: 1.07)?.ballX ?? -1, 0.3, accuracy: 0.001)
        var scored = b
        scored.leftScore = 1
        scored.phase = .serving
        buffer.append(scored, at: 1.2)
        XCTAssertEqual(buffer.sample(at: 1.21)?.leftScore, 1,
                       "Never display a partial or interpolated score")
        XCTAssertEqual(buffer.sample(at: 1.21)?.ballX, scored.ballX)
    }

    func testInterpolatorRejectsOutOfOrderArrivalAndBoundsHistory() {
        var buffer = SnapshotInterpolator()
        var state = PongSnapshot()
        state.phase = .playing
        for i in 0..<20 {
            state.ballX = Double(i) / 20
            buffer.append(state, at: Double(i) / 30)
        }
        let before = buffer.sample(at: 1)!.ballX
        state.ballX = 0
        buffer.append(state, at: -1)
        XCTAssertEqual(buffer.sample(at: 1)!.ballX, before)
        buffer.reset()
        XCTAssertNil(buffer.sample(at: 2))
    }
}

extension PongCoreTests {
    func testLocalPaddleRemainsResponsiveButEventuallyReconciles() {
        var prediction = PaddleReconciliation()
        prediction.update(y: 0.8, finished: false, at: 1)
        XCTAssertEqual(prediction.render(authoritative: 0.2, at: 1.1), 0.8)
        prediction.update(y: 0.8, finished: true, at: 1.2)
        XCTAssertEqual(prediction.render(authoritative: 0.2, at: 1.3), 0.8)
        let midway = prediction.render(authoritative: 0.2, at: 1.525)
        XCTAssertGreaterThan(midway, 0.2)
        XCTAssertLessThan(midway, 0.8)
        XCTAssertEqual(prediction.render(authoritative: 0.2, at: 1.8), 0.2)
        XCTAssertEqual(prediction.render(authoritative: 0.4, at: 1.9), 0.4,
                       "Local prediction must not persist after convergence")
        prediction.update(y: 0.7, finished: false, at: 2)
        prediction.reset()
        XCTAssertEqual(prediction.render(authoritative: 0.5, at: 2.1), 0.5)
    }
}

extension PongCoreTests {
    func testCatchupSnapshotBatchDropsOutdatedRealtimePackets() {
        var host = MatchCoordinator(), guest = MatchCoordinator()
        host.startHosting()
        guest.startJoining()
        let welcome = host.acceptHandshake(guest.handshakeRetry()!.packet).response!.packet
        let ready = guest.acceptHandshake(welcome).response!.packet
        let start = host.acceptHandshake(ready).response!.packet
        let started = guest.acceptHandshake(start).response!.packet
        _ = host.acceptHandshake(started)

        var batch = SnapshotPacketBatch()
        for _ in 0..<6 {
            if let emitted = host.tick() { batch.append(emitted) }
        }
        let outputs = batch.drain()
        XCTAssertEqual(outputs.count, 1, "Three 30Hz snapshots should collapse to the latest")
        XCTAssertEqual(outputs[0].packet.kind, .snapshot)
        XCTAssertEqual(outputs[0].packet.sequence, 3)
        XCTAssertTrue(guest.receive(outputs[0].packet))
        XCTAssertTrue(batch.drain().isEmpty)
    }

    func testCatchupSnapshotBatchPreservesCriticalScoreAndPhase() {
        let id = UUID()
        var batch = SnapshotPacketBatch()
        batch.append(OutgoingMessage(packet: MatchMessage(kind: .snapshot, matchID: id, sequence: 10,
                                                          state: PongSnapshot()),
                                     quality: .realtime))
        batch.append(OutgoingMessage(packet: MatchMessage(kind: .snapshot, matchID: id, sequence: 11,
                                                          state: PongSnapshot()),
                                     quality: .reliable))
        batch.append(OutgoingMessage(packet: MatchMessage(kind: .snapshot, matchID: id, sequence: 12,
                                                          state: PongSnapshot()),
                                     quality: .realtime))
        batch.append(OutgoingMessage(packet: MatchMessage(kind: .snapshot, matchID: id, sequence: 13,
                                                          state: PongSnapshot()),
                                     quality: .realtime))
        let messages = batch.drain()
        XCTAssertEqual(messages.map { $0.packet.sequence }, [11, 13])
        XCTAssertTrue(batch.drain().isEmpty)
    }
}

extension PongCoreTests {
    func testIngressLimitBoundsTrafficAndResetsPerSession() {
        var window = PacketIngressWindow(maxPerSecond: 3)
        XCTAssertTrue(window.admit(at: 1))
        XCTAssertTrue(window.admit(at: 1.1))
        XCTAssertTrue(window.admit(at: 1.2))
        XCTAssertFalse(window.admit(at: 1.21))
        XCTAssertFalse(window.admit(at: .nan))
        XCTAssertTrue(window.admit(at: 2))
        XCTAssertTrue(window.admit(at: 2.1))
        window.reset()
        XCTAssertTrue(window.admit(at: 2.1))
    }

    func testIngressRejectsBoundaryBurstsWithinRollingSecond() {
        // Two fixed-window bursts must not both fit in the same elapsed second.
        let capacity = 3
        let start = 10.0
        let quarterSecond = 0.25
        let eighthSecond = 0.125
        let oneSecond = 1.0
        var window = PacketIngressWindow(maxPerSecond: capacity)
        for time in [start, start + quarterSecond, start + 2 * quarterSecond] {
            XCTAssertTrue(window.admit(at: time))
        }
        XCTAssertFalse(window.admit(at: start + 3 * quarterSecond))
        // Only the oldest event has aged out; allowing a full new burst here
        // would consume up to twice the stated rolling packet budget.
        XCTAssertTrue(window.admit(at: start + oneSecond))
        XCTAssertFalse(window.admit(at: start + oneSecond + eighthSecond))
        XCTAssertTrue(window.admit(at: start + oneSecond + quarterSecond))
        XCTAssertFalse(window.admit(at: start + oneSecond + quarterSecond + eighthSecond))
        XCTAssertTrue(window.admit(at: start + oneSecond + 2 * quarterSecond))
        XCTAssertFalse(window.admit(at: .nan), "Invalid time must never admit work")
    }

    func testIngressClockDiscontinuityResetsRollingWindow() {
        let priorTime = 10.0
        let earlierTime = 0.0
        var window = PacketIngressWindow(maxPerSecond: 1)
        XCTAssertTrue(window.admit(at: priorTime))
        XCTAssertFalse(window.admit(at: priorTime))
        XCTAssertTrue(window.admit(at: earlierTime), "A clock rewind starts a new window")
        XCTAssertFalse(window.admit(at: earlierTime))
        window.reset()
        XCTAssertTrue(window.admit(at: earlierTime))
    }
}

extension PongCoreTests {
    func testFrameTimingPercentilesBoundedAndExcludeInvalidGaps() {
        var timing = FrameTimingWindow(capacity: 4)
        XCTAssertNil(timing.summary())
        timing.add(Double.nan)
        timing.add(-0.1)
        timing.add(2)
        for millis in [10.0, 20.0, 30.0, 40.0, 50.0] {
            timing.add(millis / 1000)
        }
        XCTAssertEqual(timing.summary()!.p50Milliseconds, 30, accuracy: 0.001)
        XCTAssertEqual(timing.summary()!.p95Milliseconds, 50, accuracy: 0.001)
        timing.reset()
        XCTAssertNil(timing.summary())
    }
}

extension PongCoreTests {
    func testSnapshotArrivalPercentilesIgnoreInvalidClocksAndBoundHistory() {
        var arrival = SnapshotArrivalWindow(capacity: 4)
        XCTAssertNil(arrival.summary())
        for time in [10.0, 10.03, 10.063, 10.103, 10.15] {
            arrival.observe(at: time)
        }
        arrival.observe(at: .nan)
        arrival.observe(at: 10.15) // duplicate timestamp: not an interval
        XCTAssertEqual(arrival.summary()!.p50Milliseconds, 33, accuracy: 0.001)
        XCTAssertEqual(arrival.summary()!.p95Milliseconds, 47, accuracy: 0.001)
        arrival.clearSamples()
        XCTAssertNil(arrival.summary())
        arrival.observe(at: 10.19)
        XCTAssertEqual(arrival.summary()!.p50Milliseconds, 40, accuracy: 0.001)

        arrival.observe(at: 9.0) // discontinuity invalidates old observations
        XCTAssertNil(arrival.summary())
        arrival.observe(at: 9.02)
        XCTAssertEqual(arrival.summary()!.p95Milliseconds, 20, accuracy: 0.001)
        arrival.reset()
        XCTAssertNil(arrival.summary())
        arrival.observe(at: 20)
        XCTAssertNil(arrival.summary())
    }
}

extension PongCoreTests {
    func testInvitationExpirationOnlyClearsUnansweredOffers() {
        var gate = NearbyAdmissionGate()
        XCTAssertFalse(gate.expire())
        XCTAssertTrue(gate.offer())
        XCTAssertTrue(gate.expire())
        XCTAssertEqual(gate.state, .available)
        XCTAssertFalse(gate.resolve(accept: true), "Expired consent is invalid")
        XCTAssertTrue(gate.offer())
        XCTAssertTrue(gate.resolve(accept: true))
        XCTAssertFalse(gate.expire(), "Accepted consent cannot be revoked by a stale timer")
        XCTAssertTrue(gate.didConnect())
        XCTAssertFalse(gate.expire(), "Connected session cannot be invalidated by an offer timeout")
    }
}

extension PongCoreTests {
    func testAcceptedButUnconnectedPeerCanExpireWithoutRevokingLiveMatch() {
        var gate = NearbyAdmissionGate()
        XCTAssertFalse(gate.expireUnconnectedAcceptance())
        XCTAssertTrue(gate.offer())
        XCTAssertFalse(gate.expireUnconnectedAcceptance(),
                       "Host approval must not be timed out before a decision")
        XCTAssertTrue(gate.resolve(accept: true))
        XCTAssertTrue(gate.expireUnconnectedAcceptance(),
                      "A stalled accepted invitation must free the host")
        XCTAssertEqual(gate.state, .available)
        XCTAssertFalse(gate.didConnect(), "Late connected callback cannot restore authority")
        XCTAssertTrue(gate.offer(), "Hosting must accept a subsequent invitation")
        XCTAssertTrue(gate.resolve(accept: true))
        XCTAssertTrue(gate.didConnect())
        XCTAssertFalse(gate.expireUnconnectedAcceptance(),
                       "A previously accepted match must never be expired while connected")
        XCTAssertEqual(gate.state, .connected)
    }

    func testAcceptedConnectionExpiryIsDistinctFromUnansweredOfferExpiry() {
        var gate = NearbyAdmissionGate()
        XCTAssertTrue(gate.offer())
        XCTAssertTrue(gate.expire())
        XCTAssertFalse(gate.expireUnconnectedAcceptance())
        XCTAssertTrue(gate.offer())
        XCTAssertTrue(gate.resolve(accept: true))
        XCTAssertFalse(gate.expire(), "Unanswered timer cannot expire accepted consent")
        XCTAssertTrue(gate.expireUnconnectedAcceptance(),
                      "Connect timer can revoke only an unconnected accepted attempt")
    }
}

extension PongCoreTests {
    func testNearbySessionDeadlineOrderingAndSharedPacketLimit() {
        // Host must expire an unanswered offer before MCSession invitation
        // timeout. Guests can finish their own timeout before the host
        // rotates an accepted-but-never-connected session.
        XCTAssertGreaterThan(NearbySessionPolicy.unansweredInvitationDeadlineSeconds, 0)
        XCTAssertLessThan(NearbySessionPolicy.unansweredInvitationDeadlineSeconds,
                          NearbySessionPolicy.invitationTimeoutSeconds)
        XCTAssertLessThan(NearbySessionPolicy.invitationTimeoutSeconds,
                          NearbySessionPolicy.guestConnectionDeadlineSeconds)
        XCTAssertLessThan(NearbySessionPolicy.guestConnectionDeadlineSeconds,
                          NearbySessionPolicy.acceptedConnectionDeadlineSeconds)
        XCTAssertEqual(OutboundSendPolicy.maximumBytes, MatchWireFraming.maximumPayloadBytes)
    }
}

extension PongCoreTests {
    func testSnapshotArrivalVariationAndSequenceGapsAreBoundedAndPrivate() {
        var window = SnapshotArrivalWindow(capacity: 4)
        window.observe(at: 10.0, sequence: 100)
        window.observe(at: 10.03, sequence: 101)
        window.observe(at: 10.07, sequence: 104)
        window.observe(at: 10.10, sequence: 103) // stale, must not affect timing
        window.observe(at: 10.12, sequence: 105)
        XCTAssertEqual(window.sequenceGaps, 2)
        XCTAssertEqual(window.staleSequences, 1)
        XCTAssertEqual(window.summary()!.p50Milliseconds, 40, accuracy: 0.001)
        XCTAssertEqual(window.summary()!.p99Milliseconds, 50, accuracy: 0.001)
        XCTAssertEqual(window.variationSummary()!.p95Milliseconds, 10, accuracy: 0.001)
        window.clearSamples()
        XCTAssertNil(window.summary())
        XCTAssertNil(window.variationSummary())
        XCTAssertEqual(window.sequenceGaps, 0)
        window.observe(at: 10.15, sequence: 106)
        XCTAssertEqual(window.summary()!.p50Milliseconds, 30, accuracy: 0.001)
        window.reset()
        XCTAssertEqual(window.staleSequences, 0)
        XCTAssertNil(window.summary())
    }

    func testSnapshotArrivalIgnoresLongPauseAndSequenceCounterSaturates() {
        var window = SnapshotArrivalWindow(capacity: 2)
        window.observe(at: 1, sequence: 1)
        window.observe(at: 1.03, sequence: UInt64.max)
        XCTAssertEqual(window.sequenceGaps, UInt64.max - 2)
        window.observe(at: 4.03) // no jitter spike from background pause
        XCTAssertNil(window.variationSummary())
        window.observe(at: 4.06)
        XCTAssertNil(window.variationSummary())
        window.observe(at: 4.10)
        XCTAssertEqual(window.variationSummary()!.p95Milliseconds, 10, accuracy: 0.001)
    }
}

