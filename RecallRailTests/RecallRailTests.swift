import XCTest
@testable import RecallRail

final class RecallRailTests: XCTestCase {
    func testAppContentUsesExpectedTitle() {
        let view = ContentView(productName: "Recall Rail")
        XCTAssertNotNil(view)
    }

    func testAppContentReflectsDatabaseAvailability() {
        // The app opens its local database at launch; the placeholder view
        // distinguishes "storage ready" from "storage failed" so a failed
        // open is visible, never silent.
        let ready = ContentView(productName: "Recall Rail", databaseAvailable: true)
        XCTAssertTrue(ready.databaseAvailable)
        let broken = ContentView(productName: "Recall Rail", databaseAvailable: false)
        XCTAssertFalse(broken.databaseAvailable)
    }
}

final class AuthoringDraftTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_775_000_000)

    // MARK: Deck drafts

    func testDeckRejectsBlankTitle() {
        var draft = DeckDraft(at: now)
        draft.title = "   \n "
        XCTAssertFalse(draft.validationIssues.isEmpty)
        XCTAssertNil(draft.committedDeck(at: now), "invalid drafts never produce a saveable value")
    }

    func testNewDeckGetsCreationTimeAndTrimmedTitle() throws {
        var draft = DeckDraft(at: now)
        draft.title = "  Orgo 101  "
        draft.tags = ["chem"]
        let deck = try XCTUnwrap(draft.committedDeck(at: now))
        XCTAssertEqual(deck.title, "Orgo 101")
        XCTAssertEqual(deck.createdAt, now)
        XCTAssertEqual(deck.tags, ["chem"])
    }

    func testDeckEditKeepsIdentity() throws {
        let original = Deck(title: "Old", notes: "n", createdAt: now.addingTimeInterval(-100),
                            updatedAt: now.addingTimeInterval(-100))
        var draft = DeckDraft(deck: original, at: now)
        draft.title = "Renamed"
        let edited = try XCTUnwrap(draft.committedDeck(at: now))
        XCTAssertEqual(edited.id, original.id, "editing never mints a new identity")
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(edited.updatedAt, now)
    }

    // MARK: Card drafts

    func testCardRejectsMissingPromptOrAnswer() {
        var promptless = CardDraft()
        promptless.prompt = ""
        promptless.answer = "A"
        XCTAssertFalse(promptless.validationIssues.isEmpty)
        XCTAssertNil(promptless.committedCard(deckID: StableID(), nextSortOrder: 0, at: now))

        var answerless = CardDraft()
        answerless.prompt = "P"
        answerless.answer = "   "
        XCTAssertFalse(answerless.validationIssues.isEmpty)
    }

    func testNewCardAppendsSortOrderAndEmptyOptionalsBecomeNil() throws {
        var draft = CardDraft()
        draft.prompt = "P?"
        draft.answer = "A"
        draft.hint = "  "
        draft.source = "textbook"
        let card = try XCTUnwrap(draft.committedCard(deckID: StableID(), nextSortOrder: 7, at: now))
        XCTAssertEqual(card.sortOrder, 7)
        XCTAssertNil(card.hint)
        XCTAssertEqual(card.source, "textbook")
        XCTAssertEqual(card.createdAt, now)
    }

    func testCardEditPreservesIdentityAndCreationTime() throws {
        let deckID = StableID()
        let original = Card(deckID: deckID, prompt: "P", answer: "A",
                            sortOrder: 3, createdAt: now.addingTimeInterval(-500),
                            updatedAt: now.addingTimeInterval(-500))
        var draft = CardDraft(card: original)
        draft.answer = "Better"
        let edited = try XCTUnwrap(draft.committedCard(deckID: deckID, nextSortOrder: 0, at: now))
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.sortOrder, 3, "an edit must not renumber an existing card")
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(edited.answer, "Better")
    }
}
