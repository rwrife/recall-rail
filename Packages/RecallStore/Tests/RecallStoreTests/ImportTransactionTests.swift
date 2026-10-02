import XCTest
import GRDB
@testable import RecallRailKit
@testable import RecallStore

/// Import transaction semantics: all-or-nothing by default, documented
/// valid-row-only mode, duplicate-ID rejection, and rollback on mid-way
/// database failure.
final class ImportTransactionTests: XCTestCase {

    private func makeDeck(_ repo: RecallRepository) throws -> Deck {
        let deck = StoreFixtures.deck()
        try repo.saveDeck(deck)
        return deck
    }

    func testCleanImportCommitsAllRows() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = try makeDeck(repo)
        let cards = (0..<5).map { StoreFixtures.card(deckID: deck.id, prompt: "p\($0)", sortOrder: $0) }
        let outcome = try repo.importCards(cards)
        XCTAssertEqual(outcome.committed.count, 5)
        XCTAssertTrue(outcome.rejected.isEmpty)
        XCTAssertEqual(try repo.cards(deckID: deck.id).count, 5)
    }

    func testDuplicateStableIDRejectedBeforeCommit() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = try makeDeck(repo)
        let dup = StoreFixtures.card(deckID: deck.id, prompt: "first")
        let dupAgain = Card(id: dup.id, deckID: deck.id, prompt: "different payload",
                            answer: "x", createdAt: StoreFixtures.now, updatedAt: StoreFixtures.now)
        let other = StoreFixtures.card(deckID: deck.id, prompt: "other")
        let outcome = try repo.importCards([dup, dupAgain, other], mode: .allOrNothing)
        XCTAssertEqual(outcome.committed.count, 0, "allOrNothing writes nothing when a duplicate is found")
        XCTAssertEqual(outcome.rejected.map(\.reason), ["duplicate stable ID in batch"])
        XCTAssertNil(try repo.card(id: dup.id))
        XCTAssertNil(try repo.card(id: other.id))
    }

    func testValidRowsOnlyModeCommitsValidRejectsInvalid() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = try makeDeck(repo)
        let good = StoreFixtures.card(deckID: deck.id, prompt: "good")
        let badDeck = StoreFixtures.card(deckID: StableID(), prompt: "orphan")
        let outcome = try repo.importCards([good, badDeck], mode: .validRowsOnly)
        XCTAssertEqual(outcome.committed, [good.id])
        XCTAssertEqual(outcome.rejected.count, 1)
        XCTAssertEqual(outcome.rejected[0].id, badDeck.id)
        XCTAssertEqual(try repo.cards(deckID: deck.id).count, 1)
    }

    func testMidTransactionDatabaseFailureRollsBackAllRows() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = try makeDeck(repo)
        let goodA = StoreFixtures.card(deckID: deck.id, prompt: "A")
        let goodB = StoreFixtures.card(deckID: deck.id, prompt: "B")

        // Make the second insert fail at the database level via a deferred
        // CHECK: schedule payload that violates our snapshot validation is
        // caught BEFORE the write loop, so instead we force a DB-level
        // failure by pre-creating a conflicting row between validation and
        // write: a card whose deck_id changes mid-import is impossible, so
        // emulate by enabling an immediate FK abort through direct row
        // surgery — drop the deck right after validation by importing into
        // a deck we delete from within the same write lock is not possible;
        // instead, exploit NOT NULL at DB level with a card that encodes
        // fine but whose payload is corrupted by a trigger we install for
        // this test only.
        try repo.db.rawExecute("""
            CREATE TRIGGER fail_on_B BEFORE INSERT ON card
            BEGIN
                SELECT RAISE(ABORT, 'injected import failure')
                WHERE json_extract(NEW.record, '$.prompt') = 'B';
            END;
            """)

        XCTAssertThrowsError(try { _ = try repo.importCards([goodA, goodB], mode: .validRowsOnly) }()) { error in
            guard case StoreError.rolledBack = error else {
                return XCTFail("expected rolledBack, got \(error)")
            }
        }
        // Neither A nor B survived the rolled-back savepoint.
        XCTAssertEqual(try repo.cards(deckID: deck.id).count, 0)
        try repo.db.rawExecute("DROP TRIGGER fail_on_B;")
    }

    func testReimportSameIDsUpdatesInPlace() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = try makeDeck(repo)
        var card = StoreFixtures.card(deckID: deck.id, prompt: "v1")
        _ = try repo.importCards([card])
        card.prompt = "v2"
        card.updatedAt = StoreFixtures.now.addingTimeInterval(100)
        let outcome = try repo.importCards([card], mode: .validRowsOnly)
        XCTAssertEqual(outcome.committed, [card.id])
        let stored = try XCTUnwrap(repo.card(id: card.id))
        XCTAssertEqual(stored.prompt, "v2", "stable-ID reimport updates the row")
        XCTAssertEqual(try repo.cards(deckID: deck.id).count, 1)
    }

    func testImportCarriesSchedules() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = try makeDeck(repo)
        let card = StoreFixtures.card(deckID: deck.id)
        let schedule = ScheduleState(box: 3, dueAt: StoreFixtures.now.addingTimeInterval(86_400),
                                     consecutiveRecalls: 2, algorithmVersion: 1)
        let outcome = try repo.importCards([card], schedules: [card.id: schedule], mode: .validRowsOnly)
        XCTAssertEqual(outcome.committed, [card.id])
        XCTAssertEqual(try repo.schedule(cardID: card.id), schedule)
    }
}
