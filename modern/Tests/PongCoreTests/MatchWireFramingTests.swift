import Foundation
import XCTest
@testable import PongCore

final class MatchWireFramingTests: XCTestCase {
    func testSplitAndCoalescedFrames() throws {
        let id = UUID()
        let a = MatchMessage(kind: .hello, matchID: id, sequence: 0)
        let b = MatchMessage(kind: .input, matchID: id, sequence: 1, paddleY: 0.25)
        var joined = try MatchWireFraming.encode(a)
        joined.append(try MatchWireFraming.encode(b))
        var parser = MatchWireDecoder()
        XCTAssertTrue(try parser.accept(Data(joined.prefix(2))).isEmpty)
        XCTAssertTrue(try parser.accept(Data(joined.dropFirst(2).prefix(5))).isEmpty)
        XCTAssertEqual(try parser.accept(Data(joined.dropFirst(7))), [a, b])
        XCTAssertTrue(try parser.accept(Data()).isEmpty)
    }

    func testOversizedMalformedAndZeroLengthsFailClosed() throws {
        var parser = MatchWireDecoder()
        for header: [UInt8] in [[0, 0, 0, 0], [0, 0, 16, 1]] {
            XCTAssertThrowsError(try parser.accept(Data(header))) {
                XCTAssertEqual($0 as? WireFrameError, .invalidLength)
            }
        }
        XCTAssertThrowsError(try parser.accept(Data(repeating: 0xaa, count: 17_000))) {
            XCTAssertEqual($0 as? WireFrameError, .overflow)
        }
        let m = MatchMessage(kind: .ready, matchID: UUID(), sequence: 0)
        XCTAssertEqual(try parser.accept(MatchWireFraming.encode(m)), [m],
                       "Explicitly reset decoder may serve a new authenticated session")
    }

    func testMalformedJSONRejectsAndResets() throws {
        var parser = MatchWireDecoder()
        XCTAssertThrowsError(try parser.accept(Data([0, 0, 0, 3, 0, 1, 2]))) {
            XCTAssertEqual($0 as? WireFrameError, .malformedMessage)
        }
        XCTAssertTrue(try parser.accept(Data()).isEmpty)
    }

    func testIncompleteFrameRemainsBuffered() throws {
        let m = MatchMessage(kind: .hello, matchID: UUID(), sequence: 0)
        let frame = try MatchWireFraming.encode(m)
        var parser = MatchWireDecoder()
        XCTAssertTrue(try parser.accept(Data(frame.dropLast())).isEmpty)
        XCTAssertEqual(try parser.accept(Data(frame.suffix(1))), [m])
    }
}
