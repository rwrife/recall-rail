import XCTest

/// Uses the production navigation and system file exporter/importer; no test-only restore seam.
@MainActor
final class OwnershipJourneyTests: XCTestCase {
    func testBackupExportChooseFileRestoreAndDelete() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["deck-list.create"].tap()
        let title = "Ownership \(UUID().uuidString)"
        let exportName = "rr-ownership-\(UUID().uuidString)"
        app.textFields["deck-editor.title"].tap()
        app.textFields["deck-editor.title"].typeText(title)
        app.buttons["deck-editor.save"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck-row.' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let deckID = String(row.identifier.dropFirst("deck-row.".count))
        row.tap()
        app.buttons["deck-detail.new-card"].tap()
        let prompt = app.descendants(matching: .any).matching(identifier: "card-editor.prompt").firstMatch
        prompt.tap(); prompt.typeText("Export prompt")
        let answer = app.descendants(matching: .any).matching(identifier: "card-editor.answer").firstMatch
        answer.tap(); answer.typeText("Export answer")
        app.buttons["card-editor.save"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        let ownership = app.buttons["deck-list.ownership"]
        for _ in 0..<8 where !ownership.isHittable { app.swipeUp() }
        XCTAssertTrue(ownership.waitForExistence(timeout: 5))
        ownership.tap()
        app.buttons["ownership.cards.\(deckID)"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        app.buttons["ownership.backup"].tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "System exporter must open")
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "System filename field must be available")
        name.tap()
        let oldName = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count) + exportName)
        // On a fresh simulator choose an explicit local destination when shown.
        let local = app.buttons["On My iPhone"]
        if local.exists { local.tap() }
        save.tap()
        let replace = app.buttons["Replace"]
        if replace.waitForExistence(timeout: 2) { replace.tap() }
        let message = app.staticTexts["ownership.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "Export saved.")
        let deleteBeforeRestore = app.buttons["ownership.delete"]
        for _ in 0..<8 where !deleteBeforeRestore.isHittable { app.swipeUp() }
        deleteBeforeRestore.tap()
        app.buttons["Delete everything"].tap()
        XCTAssertTrue(message.label.contains("All local records deleted"))
        let choose = app.buttons["ownership.choose"]
        for _ in 0..<8 where !choose.isHittable { app.swipeDown() }
        choose.tap()
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", exportName)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Export must be selectable through system importer")
        file.tap()
        let commit = app.buttons["ownership.commit"]
        for _ in 0..<8 where !commit.isHittable { app.swipeUp() }
        XCTAssertTrue(commit.waitForExistence(timeout: 10))
        commit.tap()
        app.buttons["Restore now"].tap()
        XCTAssertEqual(message.label, "Restore complete.")
        app.navigationBars.buttons.firstMatch.tap()
        let restored = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck-row.' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10), "Original exported deck must return after local deletion")
        let data = app.buttons["deck-list.ownership"]
        for _ in 0..<8 where !data.isHittable { app.swipeUp() }
        data.tap()
        let delete = app.buttons["ownership.delete"]
        for _ in 0..<8 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        app.buttons["Delete everything"].tap()
        XCTAssertTrue(message.label.contains("All local records deleted"))
    }

    func testCSVExportOpensSystemDestination() {
        let app = XCUIApplication(); app.launch()
        let ownership = app.buttons["deck-list.ownership"]
        for _ in 0..<8 where !ownership.isHittable { app.swipeUp() }
        ownership.tap()
        for identifier in ["ownership.decks", "ownership.attempts"] {
            let button = app.buttons[identifier]
            for _ in 0..<8 where !button.isHittable { app.swipeUp() }
            button.tap()
            XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
            app.buttons["Cancel"].tap()
        }
    }
}
