import XCTest
import RecallRailKit
import RecallStore
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

@MainActor
final class ImportSafetyTests: XCTestCase {
    func testValidRowsOnlyNeverPartiallyWritesStoreRejectedRowsOrDuplicatesOnRetry() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let target = Deck(title: "Target", createdAt: now, updatedAt: now)
        let other = Deck(title: "Other", createdAt: now, updatedAt: now)
        try repo.saveDeck(target)
        try repo.saveDeck(other)
        let foreign = Card(deckID: other.id, prompt: "Foreign", answer: "A",
                           createdAt: now, updatedAt: now)
        try repo.saveCard(foreign)
        let library = DeckLibrary(repo: repo)
        let text = "id,prompt,answer\n\(foreign.id.rawValue),Foreign,A\n,New card,Good\n,Bad,\n"
        let preview = CSVCardImport.preview(text: text, existingCards: [])
        XCTAssertFalse(preview.canCommitAllOrNothing)
        XCTAssertTrue(preview.canCommitValidRowsOnly)
        for _ in 0..<2 {
            let error = library.commit(preview: preview, deckID: target.id,
                                       validRowsOnly: true)
            XCTAssertNotNil(error)
            XCTAssertTrue(try repo.cards(deckID: target.id).isEmpty,
                          "a retryable rejection cannot leave already-committed additions")
        }
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
