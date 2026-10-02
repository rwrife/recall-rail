import XCTest
import GRDB
@testable import RecallRailKit
@testable import RecallStore

/// Independent-review hardening gates for the attempt/session commit paths:
/// stale sessions cannot double-apply evidence, cross-deck attempts are
/// rejected, and a corrupt attempt payload can never move a live schedule.
final class EvidenceIntegrityTests: XCTestCase {

    private func makeRepo() throws -> (RecallRepository, Deck) {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = StoreFixtures.deck()
        try repo.saveDeck(deck)
        return (repo, deck)
    }

    func testStaleSessionCannotDoubleApplyAttempt() throws {
        // The caller keeps an old session value (cursor 0) after the first
        // attempt already advanced the durable session to cursor 1. A retry
        // with that stale value must be rejected — otherwise the same card
        // gets a second attempt and its schedule is applied twice while the
        // cursor appears unchanged.
        let (repo, deck) = try makeRepo()
        let cardA = StoreFixtures.card(deckID: deck.id, prompt: "A", sortOrder: 0)
        let cardB = StoreFixtures.card(deckID: deck.id, prompt: "B", sortOrder: 1)
        try repo.saveCard(cardA)
        try repo.saveCard(cardB)
        var session = StudySession(deckID: deck.id, cardOrder: [cardA.id, cardB.id],
                                   mode: .tapReveal, startedAt: StoreFixtures.now,
                                   monotonicStartNanos: 0, monotonicCheckpointNanos: 0)
        try repo.saveSession(session)

        let first = try StoreFixtures.attempt(card: cardA, grade: .recalled)
        session = try repo.recordAttempt(first, advancing: session)
        let boxAfterFirst = try XCTUnwrap(repo.schedule(cardID: cardA.id)).box
        XCTAssertEqual(boxAfterFirst, 2)

        // Simulate a caller retrying with the pre-advance session value.
        var stale = session
        stale.cursor = 0
        let second = try StoreFixtures.attempt(card: cardA, grade: .recalled)
        XCTAssertThrowsError(try repo.recordAttempt(second, advancing: stale)) { error in
            guard case StoreError.invalidSessionAdvance = error else {
                return XCTFail("expected invalidSessionAdvance, got \(error)")
            }
        }
        XCTAssertEqual(try repo.attempts(cardID: cardA.id).count, 1,
                       "no second attempt row may exist")
        XCTAssertEqual(try repo.schedule(cardID: cardA.id)?.box, boxAfterFirst,
                       "schedule must not be re-applied by the rejected call")
        XCTAssertEqual(try XCTUnwrap(repo.session(id: session.id)).cursor, 1)
    }

    func testCrossDeckAttemptRejected() throws {
        // An attempt naming a deck that does not own the card passes plain
        // foreign keys but is misattributed evidence; it must be rejected
        // before commit and leave the schedule untouched.
        let (repo, deckA) = try makeRepo()
        let deckB = StoreFixtures.deck(title: "Other")
        try repo.saveDeck(deckB)
        let card = StoreFixtures.card(deckID: deckA.id)
        try repo.saveCard(card, schedule: .initial(at: StoreFixtures.now, algorithmVersion: 1))

        let honest = try StoreFixtures.attempt(card: card, grade: .recalled)
        let forged = Attempt(id: StableID(), cardID: card.id, deckID: deckB.id,
                             timestamp: honest.timestamp,
                             monotonicStartNanos: 1, monotonicEndNanos: 2,
                             grade: .recalled, mode: .tapReveal,
                             beforeSchedule: honest.beforeSchedule,
                             afterSchedule: honest.afterSchedule, algorithmVersion: 1)
        XCTAssertThrowsError(try repo.recordAttempt(forged)) { error in
            guard case StoreError.foreignKeyFailed = error else {
                return XCTFail("expected foreignKeyFailed, got \(error)")
            }
        }
        XCTAssertEqual(try repo.db.rawInt(
            "SELECT COUNT(*) FROM attempt WHERE card_id = ?", [card.id.rawValue]), 0)
        XCTAssertEqual(try repo.schedule(cardID: card.id)?.box, 1,
                       "rejected attempt must not move the schedule")
    }

    func testAdvancingSessionDeckMismatchRejected() throws {
        // The attempt card belongs to deck A, but the caller advances a
        // session belonging to deck B. Reject as an invalid session advance.
        let (repo, deckA) = try makeRepo()
        let deckB = StoreFixtures.deck(title: "Other")
        try repo.saveDeck(deckB)
        let card = StoreFixtures.card(deckID: deckA.id)
        try repo.saveCard(card)

        let session = StudySession(deckID: deckB.id, cardOrder: [card.id],
                                   mode: .tapReveal, startedAt: StoreFixtures.now,
                                   monotonicStartNanos: 0, monotonicCheckpointNanos: 0)
        let attempt = try StoreFixtures.attempt(card: card, grade: .recalled)
        XCTAssertThrowsError(try repo.recordAttempt(attempt, advancing: session)) { error in
            guard case StoreError.invalidSessionAdvance = error else {
                return XCTFail("expected invalidSessionAdvance, got \(error)")
            }
        }
        XCTAssertEqual(try repo.attempts(cardID: card.id).count, 0)
    }

    func testCorruptAttemptNeverMovesLiveSchedule() throws {
        // An after-snapshot outside the ladder is flagged corrupt. It may be
        // stored as honest anomaly evidence, but it must NEVER overwrite the
        // card's live schedule.
        let (repo, deck) = try makeRepo()
        let card = StoreFixtures.card(deckID: deck.id)
        try repo.saveCard(card, schedule: .initial(at: StoreFixtures.now, algorithmVersion: 1))

        let badAfter = ScheduleState(box: SchedulingRules.maxBox + 93,
                                     dueAt: StoreFixtures.now, algorithmVersion: 1)
        let attempt = Attempt(cardID: card.id, deckID: deck.id,
                              timestamp: StoreFixtures.now,
                              monotonicStartNanos: 1, monotonicEndNanos: 2,
                              grade: .recalled, mode: .tapReveal,
                              beforeSchedule: .initial(at: StoreFixtures.now, algorithmVersion: 1),
                              afterSchedule: badAfter, algorithmVersion: 1)
        try repo.recordAttempt(attempt)
        XCTAssertEqual(try repo.db.rawInt(
            "SELECT COUNT(*) FROM attempt WHERE card_id = ?", [card.id.rawValue]), 1,
                       "the anomaly row itself is kept as evidence")
        XCTAssertEqual(try repo.schedule(cardID: card.id)?.box, 1,
                       "a corrupt after-snapshot must never reach the live schedule")
        let evidence = try repo.evidence(cardID: card.id)
        XCTAssertEqual(evidence.count, 1)
        if case .corrupt = evidence.first { } else {
            return XCTFail("anomaly must surface as corrupt, got \(String(describing: evidence.first))")
        }
    }

    func testAdvancingPathRejectsCorruptAttemptEntirely() throws {
        // The session path needs a valid schedule transition to advance on;
        // a corrupt attempt cannot be smuggled through it at all.
        let (repo, deck) = try makeRepo()
        let card = StoreFixtures.card(deckID: deck.id)
        try repo.saveCard(card)
        let session = StudySession(deckID: deck.id, cardOrder: [card.id],
                                   mode: .tapReveal, startedAt: StoreFixtures.now,
                                   monotonicStartNanos: 0, monotonicCheckpointNanos: 0)
        try repo.saveSession(session)

        let badAfter = ScheduleState(box: 0, dueAt: StoreFixtures.now, algorithmVersion: 1)
        let attempt = Attempt(cardID: card.id, deckID: deck.id,
                              timestamp: StoreFixtures.now,
                              monotonicStartNanos: 1, monotonicEndNanos: 2,
                              grade: .again, mode: .tapReveal,
                              beforeSchedule: .initial(at: StoreFixtures.now, algorithmVersion: 1),
                              afterSchedule: badAfter, algorithmVersion: 1)
        XCTAssertThrowsError(try repo.recordAttempt(attempt, advancing: session)) { error in
            guard case StoreError.corruptRow = error else {
                return XCTFail("expected corruptRow, got \(error)")
            }
        }
        XCTAssertEqual(try repo.attempts(cardID: card.id).count, 0)
        XCTAssertEqual(try XCTUnwrap(repo.session(id: session.id)).cursor, 0)
    }

    func testStaleSaveSessionCannotRewindDurableCursor() throws {
        // After an attempt durably advanced cursor 0 → 1, an older
        // in-memory session at cursor 0 must NOT be savable — rewinding
        // the stored cursor would re-open the double-apply window (a new
        // attempt for the first card would then pass the compare-and-
        // advance guard and apply its schedule a second time).
        let (repo, deck) = try makeRepo()
        let cardA = StoreFixtures.card(deckID: deck.id, prompt: "A", sortOrder: 0)
        let cardB = StoreFixtures.card(deckID: deck.id, prompt: "B", sortOrder: 1)
        try repo.saveCard(cardA)
        try repo.saveCard(cardB)
        var session = StudySession(deckID: deck.id, cardOrder: [cardA.id, cardB.id],
                                   mode: .tapReveal, startedAt: StoreFixtures.now,
                                   monotonicStartNanos: 0, monotonicCheckpointNanos: 0)
        try repo.saveSession(session)
        session = try repo.recordAttempt(
            try StoreFixtures.attempt(card: cardA, grade: .recalled), advancing: session)
        let boxAfter = try XCTUnwrap(repo.schedule(cardID: cardA.id)).box

        var stale = session
        stale.cursor = 0
        XCTAssertThrowsError(try repo.saveSession(stale)) { error in
            guard case StoreError.invalidSessionAdvance = error else {
                return XCTFail("expected invalidSessionAdvance, got \(error)")
            }
        }
        // The rewind attempt must leave the durable cursor at 1, so the
        // replay it enabled is impossible: the guard still rejects it.
        XCTAssertEqual(try XCTUnwrap(repo.session(id: session.id)).cursor, 1)
        var replay = session
        replay.cursor = 0
        XCTAssertThrowsError(
            try repo.recordAttempt(try StoreFixtures.attempt(card: cardA, grade: .recalled),
                                   advancing: replay))
        XCTAssertEqual(try repo.schedule(cardID: cardA.id)?.box, boxAfter)

        // Same-cursor and forward saves remain legal (status/anchor updates).
        session.interrupt(at: StoreFixtures.now.addingTimeInterval(10), monotonicNanos: 10)
        try repo.saveSession(session)
        XCTAssertEqual(try XCTUnwrap(repo.session(id: session.id)).status, .interrupted)
    }

    func testCardWithEvidenceCannotChangeDecks() throws {
        // Re-parenting an evidenced card via saveCard (the ON CONFLICT
        // update path) must fail: its immutable attempts name the original
        // deck. A card without evidence may move freely.
        let (repo, deckA) = try makeRepo()
        let deckB = StoreFixtures.deck(title: "Other")
        try repo.saveDeck(deckB)
        let evidenced = StoreFixtures.card(deckID: deckA.id, prompt: "with history")
        let fresh = StoreFixtures.card(deckID: deckA.id, prompt: "no history")
        try repo.saveCard(evidenced, schedule: .initial(at: StoreFixtures.now, algorithmVersion: 1))
        try repo.saveCard(fresh, schedule: .initial(at: StoreFixtures.now, algorithmVersion: 1))
        try repo.recordAttempt(try StoreFixtures.attempt(card: evidenced, grade: .hard))

        let moved = Card(id: evidenced.id, deckID: deckB.id, prompt: evidenced.prompt,
                        answer: evidenced.answer, sortOrder: evidenced.sortOrder,
                        createdAt: evidenced.createdAt, updatedAt: evidenced.updatedAt)
        XCTAssertThrowsError(try repo.saveCard(moved))
        XCTAssertEqual(try repo.card(id: evidenced.id).flatMap { $0.deckID }, deckA.id,
                       "evidenced card stays in its recorded deck")

        // The same move for an evidenced card via import must also fail.
        XCTAssertThrowsError(try repo.importCards([moved], mode: .allOrNothing))

        // Unevidenced cards still move.
        let movedFresh = Card(id: fresh.id, deckID: deckB.id, prompt: fresh.prompt,
                              answer: fresh.answer, sortOrder: fresh.sortOrder,
                              createdAt: fresh.createdAt, updatedAt: fresh.updatedAt)
        try repo.saveCard(movedFresh)
        XCTAssertEqual(try repo.card(id: fresh.id).flatMap { $0.deckID }, deckB.id)
    }

    func testRestoreAndRawSQLCannotReparentEvidencedCard() throws {
        // The v3 trigger fires for EVERY writer: the restore path and
        // direct SQL must fail exactly like saveCard/importCards.
        let (repo, deckA) = try makeRepo()
        let deckB = StoreFixtures.deck(title: "Other")
        try repo.saveDeck(deckB)
        let evidenced = StoreFixtures.card(deckID: deckA.id)
        try repo.saveCard(evidenced, schedule: .initial(at: StoreFixtures.now, algorithmVersion: 1))
        try repo.recordAttempt(try StoreFixtures.attempt(card: evidenced, grade: .hard))

        let moved = Card(id: evidenced.id, deckID: deckB.id, prompt: evidenced.prompt,
                        answer: evidenced.answer, sortOrder: evidenced.sortOrder,
                        createdAt: evidenced.createdAt, updatedAt: evidenced.updatedAt)
        XCTAssertThrowsError(try repo.restore(decks: [], cards: [moved], mode: .allOrNothing))

        XCTAssertThrowsError(try repo.db.rawExecute(
            "UPDATE card SET deck_id = ? WHERE id = ?",
            [deckB.id.rawValue, evidenced.id.rawValue]
        ))
        XCTAssertEqual(try repo.card(id: evidenced.id).flatMap { $0.deckID }, deckA.id)
    }

    func testSameDeckEditsOnEvidencedCardStayLegal() throws {
        // The trigger keys on an actual deck change — routine same-deck
        // edits (answer, archive, reorder) on an evidenced card must pass.
        let (repo, deck) = try makeRepo()
        let card = StoreFixtures.card(deckID: deck.id)
        try repo.saveCard(card, schedule: .initial(at: StoreFixtures.now, algorithmVersion: 1))
        try repo.recordAttempt(try StoreFixtures.attempt(card: card, grade: .again))

        var edited = card
        edited.prompt = "edited prompt"
        edited.sortOrder = 42
        edited.isArchived = true
        try repo.saveCard(edited)
        let stored = try XCTUnwrap(repo.card(id: card.id))
        XCTAssertEqual(stored.prompt, "edited prompt")
        XCTAssertEqual(stored.sortOrder, 42)
        XCTAssertTrue(stored.isArchived)
        XCTAssertEqual(stored.deckID, deck.id)
    }
}
