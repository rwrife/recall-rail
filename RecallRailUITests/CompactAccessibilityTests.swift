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
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryAccessibilityXXXL"
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["deck-detail.practice"].tap()
        tap(app, "practice.resume")
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Accessible prompt 1")
        // The pre-interruption reveal is durable: the answer must already be
        // visible, and the reveal button must be gone.
        XCTAssertTrue(app.staticTexts["practice.answer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["practice.reveal"].exists)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.staticTexts["practice.prompt"].waitForExistence(timeout: 5))
            if app.buttons["practice.reveal"].waitForExistence(timeout: 2) {
                tap(app, "practice.reveal")
            }
            XCTAssertTrue(app.staticTexts["practice.answer"].exists)
            for grade in ["again", "hard", "recalled"] {
                tap(app, "practice.grade.\(grade)")
                tap(app, "practice.undo")
                XCTAssertFalse(app.buttons["practice.next"].exists)
            }
            tap(app, "practice.grade.recalled")
            tap(app, "practice.next")
        }
        XCTAssertTrue(app.staticTexts["practice.complete"].waitForExistence(timeout: 5))
    }
}
