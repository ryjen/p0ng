import XCTest

/// Simulator-only UI smoke checks. Do not claim to validate physical peer pairing.
final class P0ngSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchSoloPlayAndExit() {
        let app = XCUIApplication()
        app.launch()

        let play = app.buttons["Play against computer"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "Game menu must launch")

        play.tap()
        XCTAssertTrue(app.staticTexts["Solo · Left paddle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Exit"].exists)
        XCTAssertTrue(app.staticTexts["SERVE IN 1"].waitForExistence(timeout: 5)
                      || app.staticTexts["0"].count > 0,
                      "Court should display gameplay")

        app.buttons["Exit"].tap()
        XCTAssertTrue(app.buttons["Host nearby match"].waitForExistence(timeout: 8),
                      "Returning to the menu must stop solo play")
    }

    func testMenuContainsNearbyModes() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["p0ng"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Host nearby match"].exists)
        XCTAssertTrue(app.buttons["Join nearby match"].exists)
    }
}
