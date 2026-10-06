import XCTest

@MainActor
final class PracticeJourneyTests: XCTestCase {
    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        for _ in 0..<5 where !button.isHittable { app.swipeDown() }
        XCTAssertTrue(button.isHittable)
        button.tap()
    }

    func testAuthorPracticeUndoRelaunchAndLedger() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["deck-list.create"].tap()
        let title = "Journey \(UUID().uuidString)"
        app.textFields["deck-editor.title"].tap()
        app.textFields["deck-editor.title"].typeText(title)
        app.buttons["deck-editor.save"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.tap()
        for index in 1...2 {
            app.buttons["deck-detail.new-card"].tap()
            let prompt = app.descendants(matching: .any).matching(identifier: "card-editor.prompt").firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 5))
            prompt.tap()
            prompt.typeText("Prompt \(index)")
            app.descendants(matching: .any).matching(identifier: "card-editor.answer").firstMatch.tap()
            app.descendants(matching: .any).matching(identifier: "card-editor.answer").firstMatch.typeText("Answer \(index)")
            app.buttons["card-editor.save"].tap()
        }
        app.buttons["deck-detail.practice"].tap()
        tap(app, "practice.start")
        tap(app, "practice.reveal")
        XCTAssertTrue(app.staticTexts["practice.answer"].exists)
        tap(app, "practice.interrupt")
        tap(app, "practice.resume")
        XCTAssertTrue(app.staticTexts["practice.answer"].exists)
        tap(app, "practice.grade.hard")
        tap(app, "practice.undo")
        XCTAssertFalse(app.buttons["practice.next"].exists)
        tap(app, "practice.grade.recalled")
        tap(app, "practice.next")
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Prompt 2")
        tap(app, "practice.reveal")
        tap(app, "practice.grade.again")
        app.terminate()
        app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.tap()
        app.buttons["deck-detail.practice"].tap()
        tap(app, "practice.resume")
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Prompt 2")
        XCTAssertTrue(app.staticTexts["practice.answer"].exists)
        XCTAssertFalse(app.buttons["practice.next"].exists)
        tap(app, "practice.grade.hard")
        tap(app, "practice.next")
        tap(app, "practice.ledger")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'recalled ·'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'hard ·'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'again ·'")).firstMatch.exists)
    }
}
