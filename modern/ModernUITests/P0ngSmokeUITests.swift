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
    func testCourtFitsPortraitAndLandscape() {
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
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            device.orientation = orientation
            // Keep polling synchronous: an asynchronously interrupted XCTest
            // must not continue issuing queries against the following test's app.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))
            var windowFrame = CGRect.zero
            var courtFrame = CGRect.zero
            var fits = false
            repeat {
                windowFrame = window.frame
                courtFrame = court.frame
                let landscape = orientation == .landscapeLeft
                fits = court.exists && (windowFrame.width > windowFrame.height) == landscape &&
                    courtFrame.width > 0 && courtFrame.height > 0 &&
                    abs(courtFrame.width / courtFrame.height - 16.0 / 9.0) < 0.05 &&
                    windowFrame.insetBy(dx: -1, dy: -1).contains(courtFrame)
                if fits { break }
                Thread.sleep(forTimeInterval: 0.2)
            } while clock.now < deadline
            XCTAssertTrue(fits, "Expected fully visible 16:9 court; orientation=\(orientation.rawValue), window=\(windowFrame), court=\(courtFrame)")
        }

        app.buttons["Exit"].tap()
        XCTAssertTrue(app.buttons["Play against computer"].waitForExistence(timeout: 8))
        let haptics = app.switches["Haptic feedback"]
        let menu = app.scrollViews.firstMatch
        XCTAssertTrue(menu.exists)
        for _ in 0..<4 where !haptics.isHittable {
            menu.swipeUp()
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
