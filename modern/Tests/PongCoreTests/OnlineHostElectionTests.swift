import XCTest
@testable import PongCore

final class OnlineHostElectionTests: XCTestCase {
    func testBothPlayersIndependentlyChooseSameAuthoritativeHost() {
        XCTAssertEqual(OnlineHostElection.hostID("game-A", "game-B"), "game-A")
        XCTAssertEqual(OnlineHostElection.hostID("game-B", "game-A"), "game-A")
        XCTAssertEqual(OnlineHostElection.localIsHost("game-A", "game-B"), true)
        XCTAssertEqual(OnlineHostElection.localIsHost("game-B", "game-A"), false)
    }

    func testInvalidOrDuplicateGameCenterIDsFailClosed() {
        XCTAssertNil(OnlineHostElection.hostID("", "remote"))
        XCTAssertNil(OnlineHostElection.hostID("local", ""))
        XCTAssertNil(OnlineHostElection.hostID("same", "same"))
        XCTAssertNil(OnlineHostElection.localIsHost("same", "same"))
        XCTAssertNil(OnlineHostElection.hostID(String(repeating: "x", count: 300), "y"))
    }
}
