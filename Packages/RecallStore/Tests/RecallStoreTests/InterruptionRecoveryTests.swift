import XCTest
import GRDB
@testable import RecallRailKit
@testable import RecallStore

/// Interruption/relaunch durability against a FILE-backed database: kill
/// and reopen at any durable point and the session, schedule, and ledger
/// come back exactly — no double-written attempts.
final class InterruptionRecoveryTests: XCTestCase {

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rr-interrupt-\(UUID().uuidString).sqlite")
    }

    func testRelaunchResumesExactCardAfterDurableProgress() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let deck = StoreFixtures.deck()
        let order: [StableID]
        // --- Run 1: start a session, answer one card, background & die.
        do {
            let db = try RecallDatabase.open(at: url)
            let repo = RecallRepository(db: db)
            try repo.saveDeck(deck)
            let cards = (0..<3).map { StoreFixtures.card(deckID: deck.id, prompt: "q\($0)", sortOrder: $0) }
            for card in cards {
                try repo.saveCard(card, schedule: .initial(at: StoreFixtures.now, algorithmVersion: 1))
            }
            order = cards.map(\.id)
            var session = StudySession(deckID: deck.id, cardOrder: order, mode: .tapReveal,
                                       startedAt: StoreFixtures.now,
                                       monotonicStartNanos: 0, monotonicCheckpointNanos: 0)
            try repo.saveSession(session)

            // Durable progress on card 0: attempt + cursor advance commit
            // as ONE atomic unit, then reveal card 1, then an interrupted
            // checkpoint, then session save.
            let attempt = try StoreFixtures.attempt(card: cards[0], grade: .recalled)
            session = try repo.recordAttempt(attempt, advancing: session)
            session.isRevealed = true
            session.interrupt(at: StoreFixtures.now.addingTimeInterval(20), monotonicNanos: 20_000_000)
            try repo.saveSession(session)
        }

        // --- Run 2: process was killed; reopen.
        do {
            let db = try RecallDatabase.open(at: url)
            let repo = RecallRepository(db: db)
            let resumed = try XCTUnwrap(repo.resumableSession(deckID: deck.id))
            XCTAssertEqual(resumed.cardOrder, order)
            XCTAssertEqual(resumed.cursor, 1, "resumes on the NEXT card, not the answered one")
            XCTAssertTrue(resumed.isRevealed, "revealed state is restored exactly")
            XCTAssertEqual(try repo.attempts(cardID: order[0]).count, 1, "no double-written attempt")
            XCTAssertEqual(try repo.schedule(cardID: order[0])?.box, 2)

            // Finish the session cleanly on this run: resume, then the
            // second attempt and its cursor advance commit atomically.
            var session = resumed
            session.resume(at: StoreFixtures.now.addingTimeInterval(30), monotonicNanos: 30_000_000)
            let second = try StoreFixtures.attempt(
                card: StoreFixtures.card(deckID: deck.id), grade: .again,
                at: StoreFixtures.now.addingTimeInterval(31)
            )
            // Rebuild against the real card identity.
            let before = try XCTUnwrap(repo.schedule(cardID: order[1]))
            let after = try LeitnerScheduler().apply(grade: .again, to: before,
                                                     at: second.timestamp, attemptID: second.id)
            let realSecond = Attempt(id: second.id, cardID: order[1], deckID: deck.id,
                                     timestamp: second.timestamp,
                                     monotonicStartNanos: 31, monotonicEndNanos: 32,
                                     grade: .again, mode: .tapReveal,
                                     beforeSchedule: before,
                                     afterSchedule: after, algorithmVersion: 1)
            session = try repo.recordAttempt(realSecond, advancing: session)
            session.advance()
            XCTAssertEqual(session.status, .completed)
            try repo.saveSession(session)
        }

        // --- Run 3: completed sessions are not resume targets; history is.
        let db = try RecallDatabase.open(at: url)
        let repo = RecallRepository(db: db)
        XCTAssertNil(try repo.resumableSession(deckID: deck.id))
        XCTAssertEqual(try repo.attempts(cardID: order[1]).count, 1)
        XCTAssertEqual(try repo.integrityReport(), ["ok", "ok"])
    }

    func testCrashMidImportLeavesNothingPartiallyWritten() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try RecallDatabase.open(at: url)
        let repo = RecallRepository(db: db)
        let deck = StoreFixtures.deck()
        try repo.saveDeck(deck)

        let good = StoreFixtures.card(deckID: deck.id, prompt: "good")
        let orphan = StoreFixtures.card(deckID: StableID(), prompt: "unknown deck")

        // allOrNothing + unknown deck must reject BEFORE writing anything.
        let outcome = try repo.importCards([good, orphan], mode: .allOrNothing)
        XCTAssertTrue(outcome.committed.isEmpty)
        XCTAssertEqual(outcome.rejected.count, 1)
        XCTAssertNil(try repo.card(id: good.id), "valid row must NOT be written when batch rejects")
    }

    func testDeleteAllDataErasesEverythingIncludingEvidence() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var db = try RecallDatabase.open(at: url)
        let repo = RecallRepository(db: db)
        let deck = StoreFixtures.deck()
        try repo.saveDeck(deck)
        let card = StoreFixtures.card(deckID: deck.id)
        try repo.saveCard(card)
        try repo.recordAttempt(try StoreFixtures.attempt(card: card, grade: .hard))
        try repo.deleteAllData(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // NOTE: `deleteAllData` CLOSED the repository's connection before
        // unlinking, so this repository instance is dead by contract —
        // reading from a closed GRDB queue is undefined behavior, which is
        // exactly why the API tells callers to discard it. We verify death
        // honestly: no ghost file behind the closed handle.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))

        // A fresh open at the same path is a virgin database.
        db = try RecallDatabase.open(at: url)
        let fresh = RecallRepository(db: db)
        XCTAssertEqual(try fresh.allDecks(includeArchived: true).count, 0)
    }

    func testResetAllKeepsAppendOnlyProtectionAfterReset() throws {
        // The trigger drop/recreate is inside the reset transaction, so the
        // surviving database still refuses to edit or erase evidence rows —
        // reset never leaves history unprotected.
        let db = try RecallDatabase.openInMemory()
        let repo = RecallRepository(db: db)
        let deck = StoreFixtures.deck()
        try repo.saveDeck(deck)
        let card = StoreFixtures.card(deckID: deck.id)
        try repo.saveCard(card)
        try repo.recordAttempt(try StoreFixtures.attempt(card: card, grade: .hard))
        try repo.resetAll()
        XCTAssertEqual(try repo.allDecks(includeArchived: true).count, 0)
        XCTAssertEqual(try repo.integrityReport(), ["ok", "ok"])

        // New evidence appended after the reset is still append-only.
        try repo.saveDeck(deck)
        let card2 = StoreFixtures.card(deckID: deck.id, prompt: "post-reset")
        try repo.saveCard(card2)
        try repo.recordAttempt(try StoreFixtures.attempt(card: card2, grade: .again))
        XCTAssertThrowsError(try db.rawExecute("DELETE FROM attempt WHERE 1 = 1")) { error in
            XCTAssertTrue(String(describing: error).contains("append-only"),
                          "post-reset evidence must stay protected: \(error)")
        }
        XCTAssertThrowsError(try db.rawExecute("UPDATE attempt SET record = '{}' WHERE 1 = 1"))
        XCTAssertEqual(try repo.attempts(cardID: card2.id).count, 1)
    }
}
