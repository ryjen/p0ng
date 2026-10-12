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
}
