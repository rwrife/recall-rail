import XCTest
import GRDB
@testable import RecallRailKit
@testable import RecallStore

/// Repository CRUD, archive/delete semantics, and the guarantee that card
/// edits never rewrite recorded attempt history.
final class RepositoryTests: XCTestCase {

    private func makeRepo() throws -> RecallRepository {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = StoreFixtures.deck()
        try repo.saveDeck(deck)
        return repo
    }

    func testDeckRoundTripAndSaveUpdates() throws {
        let repo = try makeRepo()
        var deck = try XCTUnwrap(repo.allDecks().first)
        deck.title = "Renamed"
        deck.notes = "added"
        deck.tags = ["bio"]
        deck.updatedAt = StoreFixtures.now.addingTimeInterval(60)
        try repo.saveDeck(deck)
        let stored = try XCTUnwrap(repo.deck(id: deck.id))
        XCTAssertEqual(stored, deck, "full domain value must round-trip")
    }

    func testCardRoundTripAndOrdering() throws {
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        let c2 = StoreFixtures.card(deckID: deckID, prompt: "second", sortOrder: 1)
        let c1 = StoreFixtures.card(deckID: deckID, prompt: "first", sortOrder: 0)
        try repo.saveCard(c2)
        try repo.saveCard(c1)
        let cards = try repo.cards(deckID: deckID)
        XCTAssertEqual(cards.map(\.prompt), ["first", "second"], "stable sort order")
        XCTAssertEqual(try repo.card(id: c1.id), c1)
    }

    func testArchiveHidesFromListsButKeepsRow() throws {
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        let card = StoreFixtures.card(deckID: deckID)
        try repo.saveCard(card)
        try repo.setCardArchived(id: card.id, archived: true,
                                 at: StoreFixtures.now.addingTimeInterval(10))
        XCTAssertEqual(try repo.cards(deckID: deckID).count, 0)
        XCTAssertEqual(try repo.cards(deckID: deckID, includeArchived: true).count, 1)
        XCTAssertEqual(try repo.card(id: card.id)?.isArchived, true)
    }

    func testEditingCardAfterAttemptDoesNotRewriteLedger() throws {
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        var card = StoreFixtures.card(deckID: deckID)
        try repo.saveCard(card, schedule: .initial(at: StoreFixtures.now, algorithmVersion: 1))

        let recorded = try StoreFixtures.attempt(card: card, grade: .recalled)
        try repo.recordAttempt(recorded)

        // Edit the card after the attempt was recorded. A routine edit with
        // no schedule argument must PRESERVE the stored schedule (COALESCE)
        // — losing progress on a typo fix would be a data-loss bug.
        card.prompt = "totally rewritten prompt"
        card.answer = "rewritten answer"
        card.updatedAt = StoreFixtures.now.addingTimeInterval(500)
        try repo.saveCard(card)
        XCTAssertEqual(try repo.schedule(cardID: card.id), recorded.afterSchedule,
                       "card edits never wipe scheduling progress")

        let attempts = try repo.attempts(cardID: card.id)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0].grade, .recalled)
        XCTAssertEqual(attempts[0].cardID, card.id)
        XCTAssertEqual(attempts[0].timestamp, recorded.timestamp)
        XCTAssertEqual(attempts[0].beforeSchedule, recorded.beforeSchedule,
                       "ledger snapshots must be untouched by later edits")
        XCTAssertEqual(attempts[0].afterSchedule, recorded.afterSchedule)
    }

    func testAppendOnlyTriggersBlockUpdateAndDelete() throws {
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        let card = StoreFixtures.card(deckID: deckID)
        try repo.saveCard(card)
        try repo.recordAttempt(try StoreFixtures.attempt(card: card, grade: .hard))
        try repo.recordSkip(cardID: card.id, sessionID: StableID(), at: StoreFixtures.now)

        // Direct SQL against the evidence tables is refused by triggers.
        XCTAssertThrowsError(
            try repo.db.rawExecute("UPDATE attempt SET record = '{}' WHERE 1 = 1")
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("append-only"), "expected append-only refusal, got \(text)")
        }
        XCTAssertThrowsError(
            try repo.db.rawExecute("DELETE FROM attempt WHERE 1 = 1")
        )
        XCTAssertThrowsError(
            try repo.db.rawExecute("DELETE FROM skip WHERE 1 = 1")
        )
        // Evidence is intact.
        XCTAssertEqual(try repo.attempts(cardID: card.id).count, 1)
    }

    func testDeleteCardWithEvidenceFailsArchivedCardClean() throws {
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        let dirty = StoreFixtures.card(deckID: deckID, prompt: "has evidence")
        let clean = StoreFixtures.card(deckID: deckID, prompt: "no evidence")
        try repo.saveCard(dirty)
        try repo.saveCard(clean)
        try repo.recordAttempt(try StoreFixtures.attempt(card: dirty, grade: .again))

        XCTAssertThrowsError(try repo.deleteCard(id: dirty.id)) { error in
            guard case StoreError.foreignKeyFailed = error else {
                return XCTFail("expected foreignKeyFailed, got \(error)")
            }
        }
        // Archiving is the supported removal path for evidence-carrying cards.
        try repo.setCardArchived(id: dirty.id, archived: true, at: StoreFixtures.now)
        try repo.deleteCard(id: clean.id)
        XCTAssertNil(try repo.card(id: clean.id))
    }

    func testDeckDeleteCascadeAndEvidenceRestriction() throws {
        let repo = try makeRepo()
        let deck = try XCTUnwrap(repo.allDecks().first)
        let cardA = StoreFixtures.card(deckID: deck.id, prompt: "A")
        let cardB = StoreFixtures.card(deckID: deck.id, prompt: "B")
        try repo.saveCard(cardA)
        try repo.saveCard(cardB)
        try repo.recordAttempt(try StoreFixtures.attempt(card: cardA, grade: .recalled))

        // Deck still carries evidence through cardA -> RESTRICT.
        XCTAssertThrowsError(try repo.deleteDeck(id: deck.id))

        // Archive instead; deck stays readable for its history.
        try repo.setDeckArchived(id: deck.id, archived: true, at: StoreFixtures.now)
        XCTAssertEqual(try repo.allDecks().count, 0)
        XCTAssertNotNil(try repo.deck(id: deck.id))
        _ = deck
    }

    func testSaveSessionPersistsFullResumeState() throws {
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        let order = [StableID(), StableID(), StableID()]
        var session = StudySession(deckID: deckID, cardOrder: order, cursor: 1,
                                   mode: .spoken, startedAt: StoreFixtures.now,
                                   monotonicStartNanos: 10, monotonicCheckpointNanos: 12)
        try repo.saveSession(session)
        var loaded = try XCTUnwrap(repo.resumableSession(deckID: deckID))
        XCTAssertEqual(loaded, session)
        XCTAssertEqual(loaded.currentCardID, order[1])

        session.interrupt(at: StoreFixtures.now.addingTimeInterval(30), monotonicNanos: 40)
        try repo.saveSession(session)
        loaded = try XCTUnwrap(repo.resumableSession(deckID: deckID))
        XCTAssertEqual(loaded.status, .interrupted)
        XCTAssertEqual(loaded.cursor, 1)

        // Completing a session removes it from the resume set.
        session.resume(at: StoreFixtures.now.addingTimeInterval(40), monotonicNanos: 50)
        session.advance()
        session.advance()
        XCTAssertEqual(session.status, .completed)
        try repo.saveSession(session)
        XCTAssertNil(try repo.resumableSession(deckID: deckID))
    }

    func testEvidenceAssemblesCardEvidenceHonestly() throws {
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        let card = StoreFixtures.card(deckID: deckID)
        try repo.saveCard(card)
        // .hard lands due one civil day later, so the readable evidence is
        // "not due yet" — the honest bucket below is learning, not due.
        try repo.recordAttempt(try StoreFixtures.attempt(card: card, grade: .hard))
        try repo.recordSkip(cardID: card.id, sessionID: StableID(), at: StoreFixtures.now)

        // Simulate a corrupted legacy row: the append-only triggers allow
        // INSERT (history can always be appended) but a row whose payload
        // never decoded cleanly is exactly the corruption case the deriver
        // must handle. Insert it directly.
        try repo.db.rawExecute(
            """
            INSERT INTO attempt (id, card_id, deck_id, timestamp, record, schema_ok)
            VALUES (?, ?, ?, ?, '{"broken":', 0);
            """,
            [StableID().rawValue, card.id.rawValue, deckID.rawValue,
             StoreFixtures.now.timeIntervalSince1970]
        )
        let evidence = try repo.evidence(cardID: card.id)
        XCTAssertEqual(evidence.count, 3)
        XCTAssertEqual(evidence.filter { if case .corrupt = $0 { true } else { false } }.count, 1,
                       "undecodable row must surface as corrupt, never a grade")
        XCTAssertEqual(evidence.filter { if case .attempt = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(evidence.filter { if case .skipped = $0 { true } else { false } }.count, 1)

        // The raw ledger view refuses to hand back a corrupt row.
        XCTAssertThrowsError(try repo.attempts(cardID: card.id)) { error in
            guard case StoreError.corruptRow = error else {
                return XCTFail("expected corruptRow, got \(error)")
            }
        }

        let deriver = MasteryDeriver(scheduler: LeitnerScheduler())
        let state = deriver.derive(evidence: evidence, at: StoreFixtures.now)
        XCTAssertEqual(state, .learning,
                       "one readable 'hard' plus corrupt+skip evidence stays learning, never due/recalled")
    }

    func testIdentityMismatchedPayloadIsCorruptNotAttributed() throws {
        // A row whose payload DECODES but claims a different card/deck than
        // the row's indexed columns must surface as corrupt — never as
        // graded evidence for the card it was filed under.
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        let card = StoreFixtures.card(deckID: deckID)
        try repo.saveCard(card)
        let other = StoreFixtures.card(deckID: deckID, prompt: "other")

        // A legitimate attempt belongs to `other` but gets filed under `card`
        // (simulating a mis-indexed or tampered row). The payload stays
        // valid JSON; only its identity disagrees.
        let foreign = try StoreFixtures.attempt(card: other, grade: .recalled)
        let record = try Snapshots.canonicalPayload(foreign)
        try repo.db.rawExecute(
            """
            INSERT INTO attempt (id, card_id, deck_id, timestamp, record, schema_ok)
            VALUES (?, ?, ?, ?, ?, 1);
            """,
            [foreign.id.rawValue, card.id.rawValue, deckID.rawValue,
             foreign.timestamp.timeIntervalSince1970, record]
        )

        let evidence = try repo.evidence(cardID: card.id)
        XCTAssertEqual(evidence.count, 1)
        if case .corrupt = evidence.first { } else {
            return XCTFail("identity-mismatched payload must be corrupt, got \(String(describing: evidence.first))")
        }
        XCTAssertThrowsError(try repo.attempts(cardID: card.id)) { error in
            guard case StoreError.corruptRow = error else {
                return XCTFail("expected corruptRow, got \(error)")
            }
        }
        // The deriver must not see it as a recall for `card`.
        let state = MasteryDeriver(scheduler: LeitnerScheduler())
            .derive(evidence: evidence, at: StoreFixtures.now)
        XCTAssertEqual(state, .insufficientEvidence,
                       "corrupt-only evidence is never promoted to a grade")
    }

    func testSchemaFlaggedReadablePayloadStaysCorrupt() throws {
        // A payload written as readable=false remains corrupt even though
        // the record JSON still decodes — honest labeling beats leniency.
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        let card = StoreFixtures.card(deckID: deckID)
        try repo.saveCard(card)
        let attempt = try StoreFixtures.attempt(card: card, grade: .recalled)
        let record = try Snapshots.canonicalPayload(attempt)
        try repo.db.rawExecute(
            """
            INSERT INTO attempt (id, card_id, deck_id, timestamp, record, schema_ok)
            VALUES (?, ?, ?, ?, ?, 0);
            """,
            [attempt.id.rawValue, card.id.rawValue, deckID.rawValue,
             attempt.timestamp.timeIntervalSince1970, record]
        )
        let evidence = try repo.evidence(cardID: card.id)
        XCTAssertEqual(evidence.count, 1)
        if case .corrupt = evidence.first { } else {
            return XCTFail("schema_ok=0 must stay corrupt, got \(String(describing: evidence.first))")
        }
    }

    func testRecordAttemptAdvancingCommitsAtomically() throws {
        // The attempt, schedule, cursor, and revealed state commit as one
        // durable unit: a rejected advance (wrong current card) leaves the
        // attempt ledger, schedule, and session all untouched.
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        let cardA = StoreFixtures.card(deckID: deckID, prompt: "A", sortOrder: 0)
        let cardB = StoreFixtures.card(deckID: deckID, prompt: "B", sortOrder: 1)
        try repo.saveCard(cardA)
        try repo.saveCard(cardB)
        var session = StudySession(deckID: deckID, cardOrder: [cardA.id, cardB.id],
                                   mode: .tapReveal, startedAt: StoreFixtures.now,
                                   monotonicStartNanos: 0, monotonicCheckpointNanos: 0)
        try repo.saveSession(session)

        // Wrong-card attempt: rejected, nothing changed.
        let mismatched = try StoreFixtures.attempt(card: cardB, grade: .recalled)
        XCTAssertThrowsError(try repo.recordAttempt(mismatched, advancing: session)) { error in
            guard case StoreError.invalidSessionAdvance = error else {
                return XCTFail("expected invalidSessionAdvance, got \(error)")
            }
        }
        XCTAssertEqual(try repo.attempts(cardID: cardB.id).count, 0)
        XCTAssertEqual(try XCTUnwrap(repo.session(id: session.id)).cursor, 0)

        // Correct-card attempt with reveal: one call commits everything.
        session.isRevealed = true
        let good = try StoreFixtures.attempt(card: cardA, grade: .recalled)
        let advanced = try repo.recordAttempt(good, advancing: session)
        XCTAssertEqual(advanced.cursor, 1)
        XCTAssertFalse(advanced.isRevealed, "advance resets reveal for the next card")

        let stored = try XCTUnwrap(repo.resumableSession(deckID: deckID))
        XCTAssertEqual(stored.cursor, 1, "session cursor durable in the same commit")
        XCTAssertFalse(stored.isRevealed)
        XCTAssertEqual(try repo.attempts(cardID: cardA.id).count, 1)
        XCTAssertEqual(try repo.schedule(cardID: cardA.id)?.box, 2)
    }

    func testCompletedSessionCannotAdvance() throws {
        let repo = try makeRepo()
        let deckID = try XCTUnwrap(repo.allDecks().first).id
        let card = StoreFixtures.card(deckID: deckID)
        try repo.saveCard(card)
        var session = StudySession(deckID: deckID, cardOrder: [card.id], mode: .tapReveal,
                                   startedAt: StoreFixtures.now,
                                   monotonicStartNanos: 0, monotonicCheckpointNanos: 0)
        session.advance()
        XCTAssertEqual(session.status, .completed)
        let attempt = try StoreFixtures.attempt(card: card, grade: .again)
        XCTAssertThrowsError(try repo.recordAttempt(attempt, advancing: session)) { error in
            guard case StoreError.invalidSessionAdvance = error else {
                return XCTFail("expected invalidSessionAdvance, got \(error)")
            }
        }
        XCTAssertEqual(try repo.attempts(cardID: card.id).count, 0)
    }
}
