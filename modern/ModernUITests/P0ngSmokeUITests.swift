import XCTest
import UIKit

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
        // The score and role are intentionally one accessible scoreboard element.
        XCTAssertTrue(app.descendants(matching: .any)["pong.scoreboard"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Exit"].exists)

        app.buttons["Exit"].tap()
        XCTAssertTrue(app.buttons["Host nearby match"].waitForExistence(timeout: 8),
                      "Returning to the menu must stop solo play")
    }

    @MainActor
    func testSoloScoreboardAnnouncesBothScoringSides() {
        let app = XCUIApplication()
        app.launch()
        let play = app.buttons["Play against computer"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        play.tap()

        let scoreboard = app.descendants(matching: .any)["pong.scoreboard"]
        XCTAssertTrue(scoreboard.waitForExistence(timeout: 8))
        XCTAssertEqual(scoreboard.label, "Scoreboard")
        let announced = scoreboard.value as? String ?? ""
        XCTAssertTrue(announced.localizedCaseInsensitiveContains("left"))
        XCTAssertTrue(announced.localizedCaseInsensitiveContains("right"))
        XCTAssertTrue(announced.localizedCaseInsensitiveContains("solo"),
                      "Combining score elements must not hide the current player role")
    }

    @MainActor
    func testCourtFitsPortraitAndLandscape() async throws {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launch()
        let play = app.buttons["Play against computer"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        play.tap()

        let court = app.descendants(matching: .any)["pong.court"]
        XCTAssertTrue(court.waitForExistence(timeout: 8))

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            device.orientation = orientation
            // Keep XCTest element access on the main actor while rotation settles.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))
            var fits = false
            repeat {
                let window = app.frame
                let frame = court.frame
                let landscape = orientation == .landscapeLeft
                fits = court.exists && (window.width > window.height) == landscape &&
                    frame.width > 0 && frame.height > 0 &&
                    abs(frame.width / frame.height - 16.0 / 9.0) < 0.05 &&
                    window.insetBy(dx: -1, dy: -1).contains(frame)
                if fits { break }
                try await Task.sleep(for: .milliseconds(200))
            } while clock.now < deadline
            XCTAssertTrue(fits, "The complete 16:9 court must remain visible after rotation")
        }

        // Compact-height menus must keep all actions reachable after exiting.
        app.buttons["Exit"].tap()
        XCTAssertTrue(app.buttons["Play against computer"].waitForExistence(timeout: 8))
        let haptics = app.switches["Haptic feedback"]
        for _ in 0..<4 where !haptics.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(haptics.isHittable)
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
