import XCTest

/// Simulator-only UI smoke checks. Do not claim to validate physical peer pairing.
final class P0ngSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchSoloPlayAndExit() {
        let app = XCUIApplication()
        app.launch()

        let play = app.buttons["Play against computer"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "Game menu must launch")

        play.tap()
        XCTAssertTrue(app.staticTexts["Solo · Left paddle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Exit"].exists)

        app.buttons["Exit"].tap()
        XCTAssertTrue(app.buttons["Host nearby match"].waitForExistence(timeout: 8),
                      "Returning to the menu must stop solo play")
    }

    @MainActor
    func testMenuContainsNearbyModes() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["pong.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Host nearby match"].exists)
        XCTAssertTrue(app.buttons["Join nearby match"].exists)
    }
}
