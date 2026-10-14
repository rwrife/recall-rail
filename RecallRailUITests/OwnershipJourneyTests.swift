import XCTest

/// Uses the production navigation and system file exporter/importer; no test-only restore seam.
@MainActor
final class OwnershipJourneyTests: XCTestCase {
    private func cancelExporter(_ app: XCUIApplication) -> Bool {
        // The host screen also owns a BackButton; only tap picker controls.
        let picker = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        for _ in 0..<3 {
            let cancel = app.buttons.matching(NSPredicate(format: "label ==[c] 'cancel'")).firstMatch
            if cancel.exists { cancel.tap() } else if picker.buttons["BackButton"].exists {
                picker.buttons["BackButton"].tap()
            } else { break }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if !app.buttons["Save"].exists && app.buttons["ownership.backup"].isHittable { return true }
                usleep(200_000)
            }
        }
        XCTFail("System document exporter could not be dismissed: \(app.debugDescription)")
        return false
    }

    func testBackupExportChooseFileRestoreAndDelete() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["deck-list.create"].tap()
        let title = "Ownership \(UUID().uuidString)"
        let exportName = "RecallRail-backup"
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
        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10), "System document exporter must appear: \(app.debugDescription)")
        guard cancelExporter(app) else { return }
        app.buttons["ownership.backup"].tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "System exporter must open")
        let deadlineSave = Date().addingTimeInterval(5)
        while Date() < deadlineSave && !save.isEnabled { usleep(200_000) }
        XCTAssertTrue(save.isEnabled, "System Save disabled: \(app.debugDescription)")
        save.tap()
        let replace = app.buttons["Replace"]
        if replace.waitForExistence(timeout: 2) { replace.tap() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && save.exists { usleep(200_000) }
        guard !save.exists else {
            XCTFail("Save did not dismiss document exporter: \(app.debugDescription)")
            return
        }
        let message = app.staticTexts["ownership.message"]
        for _ in 0..<8 where !message.exists { app.swipeUp() }
        XCTAssertTrue(message.waitForExistence(timeout: 10), app.debugDescription)
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

    func testArchivedDeckCardExportIsReachable() {
        let app = XCUIApplication(); app.launch()
        app.buttons["deck-list.create"].tap()
        let title = "Archived ownership \(UUID().uuidString)"
        app.textFields["deck-editor.title"].tap()
        app.textFields["deck-editor.title"].typeText(title)
        app.buttons["deck-editor.save"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck-row.' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let deckID = String(row.identifier.dropFirst("deck-row.".count))
        row.swipeLeft()
        app.buttons["Archive"].tap()
        let ownership = app.buttons["deck-list.ownership"]
        for _ in 0..<8 where !ownership.isHittable { app.swipeUp() }
        ownership.tap()
        let export = app.buttons["ownership.cards.\(deckID)"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        export.tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10), "Archived deck exporter must appear: \(app.debugDescription)")
        _ = cancelExporter(app)
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
            _ = cancelExporter(app)
        }
    }
}
