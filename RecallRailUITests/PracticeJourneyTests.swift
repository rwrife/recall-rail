import XCTest

@MainActor
final class PracticeJourneyTests: XCTestCase {
    func testAuthorPracticeUndoRelaunchAndLedger() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["deck-list.create"].tap()
        let title = "Journey \(UUID().uuidString)"
        app.textFields["deck-editor.title"].tap()
        app.textFields["deck-editor.title"].typeText(title)
        app.buttons["deck-editor.save"].tap()
        app.buttons.containing(.staticText, identifier: title).firstMatch.tap()
        for index in 1...2 {
            app.buttons["deck-detail.new-card"].tap()
            let prompt = app.textViews["card-editor.prompt"]
            XCTAssertTrue(prompt.waitForExistence(timeout: 5))
            prompt.tap()
            prompt.typeText("Prompt \(index)")
            app.textViews["card-editor.answer"].tap()
            app.textViews["card-editor.answer"].typeText("Answer \(index)")
            app.buttons["card-editor.save"].tap()
        }
        app.buttons["deck-detail.practice"].tap()
        app.buttons["practice.start"].tap()
        app.buttons["practice.reveal"].tap()
        XCTAssertTrue(app.staticTexts["practice.answer"].exists)
        app.buttons["practice.grade.hard"].tap()
        app.buttons["practice.undo"].tap()
        XCTAssertFalse(app.buttons["practice.next"].exists)
        app.buttons["practice.grade.recalled"].tap()
        app.buttons["practice.next"].tap()
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Prompt 2")
        app.buttons["practice.reveal"].tap()
        app.buttons["practice.grade.again"].tap()
        app.terminate()
        app.launch()
        app.buttons.containing(.staticText, identifier: title).firstMatch.tap()
        app.buttons["deck-detail.practice"].tap()
        app.buttons["practice.resume"].tap()
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Prompt 2")
        XCTAssertTrue(app.staticTexts["practice.answer"].exists)
        XCTAssertFalse(app.buttons["practice.next"].exists)
        app.buttons["practice.grade.hard"].tap()
        app.buttons["practice.next"].tap()
        app.buttons["practice.ledger"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'recalled ·'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'hard ·'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'again ·'")).firstMatch.exists)
    }
}
