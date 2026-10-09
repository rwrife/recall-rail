import XCTest
import UIKit

@MainActor
final class CompactAccessibilityTests: XCTestCase {
    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 5), id)
        for _ in 0..<8 where !button.isHittable { app.swipeUp() }
        for _ in 0..<8 where !button.isHittable { app.swipeDown() }
        XCTAssertTrue(button.isHittable, id)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44, id)
        XCTAssertGreaterThanOrEqual(button.frame.width, 44, id)
        button.tap()
    }

    func testAXLargeTypePortraitLandscapeRevealGradeUndoAndResume() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        app.buttons["deck-list.create"].tap()
        let title = "Accessibility \(UUID().uuidString)"
        app.textFields["deck-editor.title"].tap()
        app.textFields["deck-editor.title"].typeText(title)
        app.buttons["deck-editor.save"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck-row.' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        for index in 1...2 {
            app.buttons["deck-detail.new-card"].tap()
            let prompt = app.descendants(matching: .any).matching(identifier: "card-editor.prompt").firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 5))
            prompt.tap()
            prompt.typeText("Accessible prompt \(index)")
            let answer = app.descendants(matching: .any).matching(identifier: "card-editor.answer").firstMatch
            answer.tap()
            answer.typeText("Accessible answer \(index)")
            app.buttons["card-editor.save"].tap()
        }
        app.buttons["deck-detail.practice"].tap()
        tap(app, "practice.start")
        tap(app, "practice.reveal")
        tap(app, "practice.interrupt")
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "--rr-size-probe"]
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryAccessibilityXXXL"
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["deck-detail.practice"].tap()
        // Prove the accessibility size actually applied inside the app rather
        // than trusting the launch argument. UIKit surfaces the raw category
        // value; gate on the accessibility prefix, not an exact spelling.
        let probe = app.staticTexts["practice.size-category"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        XCTAssertTrue(probe.label.contains("UICTContentSizeCategoryAccessibility"), probe.label)
        tap(app, "practice.resume")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "AX5 portrait practice"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Accessible prompt 1")
        // The pre-interruption reveal is durable: the answer must already be
        // visible, and the reveal button must be gone.
        XCTAssertTrue(app.staticTexts["practice.answer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["practice.reveal"].exists)

        let window = app.windows.firstMatch
        func waitForGeometry(portrait: Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let frame = window.frame
                if portrait, frame.height > frame.width { return true }
                if !portrait, frame.width > frame.height { return true }
                usleep(100_000)
            }
            return false
        }
        XCTAssertTrue(waitForGeometry(portrait: true))

        for grade in ["again", "hard", "recalled"] {
            tap(app, "practice.grade.\(grade)")
            tap(app, "practice.undo")
            XCTAssertFalse(app.buttons["practice.next"].exists)
        }
        // A revealed card with a pending grade must survive rotation intact.
        tap(app, "practice.grade.hard")
        let pending = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Pending: hard'")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForGeometry(portrait: false))
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "AX5 landscape pending grade"
        landscape.lifetime = .keepAlways
        add(landscape)
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Accessible prompt 1")
        XCTAssertTrue(app.staticTexts["practice.answer"].exists)
        XCTAssertTrue(pending.exists)
        tap(app, "practice.undo")
        tap(app, "practice.grade.recalled")
        tap(app, "practice.next")

        // Card 2 in landscape completes the session.
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Accessible prompt 2")
        tap(app, "practice.reveal")
        for grade in ["again", "hard", "recalled"] {
            tap(app, "practice.grade.\(grade)")
            tap(app, "practice.undo")
        }
        tap(app, "practice.grade.recalled")
        tap(app, "practice.next")
        XCTAssertTrue(app.staticTexts["practice.complete"].waitForExistence(timeout: 5))
    }
}
