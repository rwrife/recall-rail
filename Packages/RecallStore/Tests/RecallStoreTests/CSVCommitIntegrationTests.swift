import Foundation
import XCTest
import GRDB
@testable import RecallRailKit
@testable import RecallStore

/// End-to-end import-path coverage: the pure-Swift CSV preview feeds the
/// transactional repository, so a malformed file can never partially
/// contaminate a deck and a valid update can never duplicate a card.
final class CSVCommitIntegrationTests: XCTestCase {

    static let now = Date(timeIntervalSince1970: 1_775_000_000)

    func makeRepo() throws -> (RecallRepository, Deck) {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = Deck(title: "Import target", createdAt: Self.now, updatedAt: Self.now)
        try repo.saveDeck(deck)
        return (repo, deck)
    }

    func testCommitWritesAddsAndUpdatesInOnePass() throws {
        let (repo, deck) = try makeRepo()
        let existing = Card(deckID: deck.id, prompt: "Old", answer: "Old",
                            sortOrder: 0, createdAt: Self.now, updatedAt: Self.now)
        try repo.saveCard(existing)

        let text = """
        id,prompt,answer,tags,sort
        \(existing.id.rawValue),New,New,updated,0
        ,Brand new,Card,new,1
        """
        let cards = try repo.cards(deckID: deck.id)
        let preview = CSVCardImport.preview(text: text, existingCards: cards)
        XCTAssertTrue(preview.canCommitAllOrNothing)

        let materialized = CSVCardImport.cards(from: preview, deckID: deck.id,
                                               existingCards: cards, at: Self.now)
        let outcome = try repo.importCards(materialized)
        XCTAssertEqual(outcome.rejected.count, 0)
        XCTAssertEqual(outcome.committed.count, 2)

        let stored = try repo.cards(deckID: deck.id)
        XCTAssertEqual(stored.count, 2)
        let updated = stored.first { $0.id == existing.id }
        XCTAssertEqual(updated?.prompt, "New")
        XCTAssertEqual(updated?.tags, ["updated"])
        // Update must not duplicate the row nor mint a fresh identity.
        XCTAssertEqual(Set(stored.map(\.id)).count, 2)
    }

    func testPreviewBlocksAllOrNothingWhenRowsHaveErrors() throws {
        let (repo, deck) = try makeRepo()
        let text = """
        prompt,answer
        Good row,X
        ,Missing prompt
        """
        let cards = try repo.cards(deckID: deck.id)
        let preview = CSVCardImport.preview(text: text, existingCards: cards)
        XCTAssertFalse(preview.canCommitAllOrNothing)

        // Preview is the ONLY carrier of row parse errors: passing only
        // materialized valid rows to the store would silently lose the
        // invalid row. The UI must block this all-or-nothing commit.
        let materialized = CSVCardImport.cards(from: preview, deckID: deck.id,
                                               existingCards: cards, at: Self.now)
        XCTAssertEqual(materialized.count, 1)
        XCTAssertFalse(materialized.contains { $0.prompt.isEmpty })
        XCTAssertTrue(try repo.cards(deckID: deck.id).isEmpty)
    }

    func testValidRowsOnlyCommitsValidAndReportsRejected() throws {
        let (repo, deck) = try makeRepo()
        // A file whose SECOND row duplicates the first row's stable ID.
        let text = """
        id,prompt,answer
        2A111111-1111-1111-1111-111111111111,First,X
        2A111111-1111-1111-1111-111111111111,Duplicate,Y
        2A999999-9999-9999-9999-999999999999,Valid,Z
        """
        let preview = CSVCardImport.preview(text: text, existingCards: [])
        XCTAssertFalse(preview.canCommitAllOrNothing)
        XCTAssertTrue(preview.canCommitValidRowsOnly)

        let cards = try repo.cards(deckID: deck.id)
        let materialized = CSVCardImport.cards(from: preview, deckID: deck.id,
                                               existingCards: cards, at: Self.now)
        let outcome = try repo.importCards(materialized, mode: .validRowsOnly)
        XCTAssertEqual(outcome.committed.count, 2)
        let stored = try repo.cards(deckID: deck.id)
        XCTAssertEqual(Set(stored.map(\.prompt)), ["First", "Valid"])
    }

    func testCrossDeckIDIsRejectedNeverReparented() throws {
        let (repo, deck) = try makeRepo()
        let other = Deck(title: "Other", createdAt: Self.now, updatedAt: Self.now)
        try repo.saveDeck(other)
        let foreign = Card(deckID: other.id, prompt: "Foreign", answer: "Card",
                           sortOrder: 0, createdAt: Self.now, updatedAt: Self.now)
        try repo.saveCard(foreign)

        // A hand-edited CSV claiming the foreign card for `deck`.
        let text = "id,prompt,answer\n\(foreign.id.rawValue),Stolen,X\n"
        let preview = CSVCardImport.preview(text: text, existingCards: [])
        let materialized = CSVCardImport.cards(from: preview, deckID: deck.id,
                                               existingCards: [], at: Self.now)

        let outcome = try repo.importCards(materialized, mode: .validRowsOnly)
        XCTAssertEqual(outcome.rejected.count, 1)
        XCTAssertTrue(outcome.rejected.first?.reason.contains("another deck") ?? false)
        // The card still belongs to its original deck.
        let still = try repo.card(id: foreign.id)
        XCTAssertEqual(still?.deckID, other.id)
        XCTAssertEqual(still?.prompt, "Foreign")
    }

    func testEvidencedCardCannotMoveDecksEvenViaStoreLevelImport() throws {
        let (repo, deck) = try makeRepo()
        let other = Deck(title: "Other", createdAt: Self.now, updatedAt: Self.now)
        try repo.saveDeck(other)
        let card = Card(deckID: deck.id, prompt: "P", answer: "A",
                        sortOrder: 0, createdAt: Self.now, updatedAt: Self.now)
        try repo.saveCard(card)
        try repo.recordAttempt(StoreFixtures.attempt(card: card, grade: .recalled))

        let movedCard = Card(id: card.id, deckID: other.id, prompt: card.prompt,
                             answer: card.answer, hint: card.hint, source: card.source,
                             tags: card.tags, sortOrder: card.sortOrder,
                             createdAt: card.createdAt, updatedAt: card.updatedAt)
        let outcome = try repo.importCards([movedCard], mode: .validRowsOnly)
        XCTAssertEqual(outcome.rejected.count, 1)
        let schedule = try repo.schedule(cardID: card.id)
        XCTAssertNotNil(schedule, "the evidenced card's schedule must be untouched")
    }

    func testAtomicReorderRejectsPartialOrForeignLists() throws {
        let (repo, deck) = try makeRepo()
        let other = Deck(title: "Other", createdAt: Self.now, updatedAt: Self.now)
        try repo.saveDeck(other)
        let first = Card(deckID: deck.id, prompt: "First", answer: "A", sortOrder: 0,
                         createdAt: Self.now, updatedAt: Self.now)
        let second = Card(deckID: deck.id, prompt: "Second", answer: "B", sortOrder: 1,
                          createdAt: Self.now, updatedAt: Self.now)
        let foreign = Card(deckID: other.id, prompt: "Foreign", answer: "C",
                           createdAt: Self.now, updatedAt: Self.now)
        for card in [first, second, foreign] { try repo.saveCard(card) }
        XCTAssertThrowsError(try repo.reorderCards(deckID: deck.id, orderedIDs: [second.id], at: Self.now))
        XCTAssertThrowsError(try repo.reorderCards(deckID: deck.id,
                                                    orderedIDs: [second.id, foreign.id], at: Self.now))
        XCTAssertEqual(try repo.cards(deckID: deck.id).map(\.id), [first.id, second.id])
        try repo.reorderCards(deckID: deck.id, orderedIDs: [second.id, first.id], at: Self.now)
        XCTAssertEqual(try repo.cards(deckID: deck.id).map(\.id), [second.id, first.id])
        XCTAssertEqual(try repo.card(id: first.id)?.sortOrder, 1)
    }

    func testSaveDeckPreserveCreatedAtFlagKeepsCreationInstant() throws {
        let (repo, deck) = try makeRepo()
        let original = try XCTUnwrap(repo.deck(id: deck.id))
        var edited = original
        edited.title = "Renamed"
        edited.updatedAt = Self.now.addingTimeInterval(3600)
        try repo.saveDeck(edited, preserveCreatedAt: true)
        let stored = try XCTUnwrap(repo.deck(id: deck.id))
        XCTAssertEqual(stored.title, "Renamed")
        XCTAssertEqual(stored.createdAt, original.createdAt,
                       "an in-place edit must never rewind creation ordering")
    }
}
