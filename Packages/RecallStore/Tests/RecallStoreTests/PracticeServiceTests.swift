import XCTest
import GRDB
import RecallRailKit
@testable import RecallStore

final class PracticeServiceTests: XCTestCase {
    func testTransactionRejectsChangedOrderAndScheduleWithoutPartialWrites() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = StoreFixtures.deck()
        let a = StoreFixtures.card(deckID: deck.id)
        let b = StoreFixtures.card(deckID: deck.id, sortOrder: 1)
        try repo.saveDeck(deck)
        try repo.saveCard(a)
        try repo.saveCard(b)
        var run = try PracticeService.start(repo: repo, deckID: deck.id, selection: PracticeSelection(), mode: .tapReveal, at: StoreFixtures.now, nanos: 0)
        try run.reveal(repo: repo)
        try run.grade(.hard, repo: repo, at: StoreFixtures.now, nanos: 10)
        let pending = try XCTUnwrap(run.pending)
        var forged = run.session
        forged.cardOrder = [a.id]
        XCTAssertThrowsError(try repo.recordAttempt(pending, advancing: forged))
        XCTAssertEqual(try repo.attempts(cardID: a.id).count, 0)
        let changed = ScheduleState(box: 3, dueAt: StoreFixtures.now, algorithmVersion: 1)
        try repo.setSchedule(changed, cardID: a.id)
        for _ in 0..<2 { XCTAssertThrowsError(try run.next(repo: repo, nanos: 20)) }
        XCTAssertEqual(try repo.schedule(cardID: a.id), changed)
        XCTAssertEqual(try repo.session(id: run.session.id)?.cursor, 0)
        XCTAssertEqual(try repo.attempts(cardID: a.id).count, 0)
    }

    func testServiceFileRoundTripDropsPendingAndRejectsStaleRetry() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("practice-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let deck = StoreFixtures.deck()
        let card = StoreFixtures.card(deckID: deck.id)
        let sessionID: StableID
        do {
            let repo = RecallRepository(db: try RecallDatabase.open(at: url))
            try repo.saveDeck(deck)
            try repo.saveCard(card)
            var run = try PracticeService.start(repo: repo, deckID: deck.id, selection: PracticeSelection(), mode: .spoken, at: StoreFixtures.now, nanos: 500)
            try run.reveal(repo: repo)
            try run.grade(.again, repo: repo, at: StoreFixtures.now, nanos: 900)
            sessionID = run.session.id
        }
        let repo = RecallRepository(db: try RecallDatabase.open(at: url))
        var run = try PracticeService.resume(repo: repo, session: XCTUnwrap(repo.session(id: sessionID)), at: StoreFixtures.now.addingTimeInterval(-500), nanos: 0)
        XCTAssertNil(run.pending)
        XCTAssertTrue(run.session.isRevealed)
        XCTAssertEqual(run.session.cardOrder, [card.id])
        XCTAssertTrue(try repo.attempts(cardID: card.id).isEmpty)
        try run.grade(.recalled, repo: repo, at: StoreFixtures.now, nanos: 2_000_000)
        var stale = run
        try run.next(repo: repo, nanos: 3_000_000)
        XCTAssertThrowsError(try stale.next(repo: repo, nanos: 4_000_000))
        XCTAssertEqual(try repo.attempts(cardID: card.id).count, 1)
        XCTAssertNil(try repo.resumableSession(deckID: deck.id))
    }
    func testPendingUndoInterruptionAndPerCardTiming() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = StoreFixtures.deck()
        let a = StoreFixtures.card(deckID: deck.id)
        let b = StoreFixtures.card(deckID: deck.id, sortOrder: 1)
        try repo.saveDeck(deck)
        try repo.saveCard(a)
        try repo.saveCard(b)
        var run = try PracticeService.start(repo: repo, deckID: deck.id, selection: PracticeSelection(), mode: .tapReveal, at: StoreFixtures.now, nanos: 1_000_000)
        try run.reveal(repo: repo)
        try run.grade(.hard, repo: repo, at: StoreFixtures.now, nanos: 11_000_000)
        XCTAssertEqual(try repo.attempts(cardID: a.id).count, 0)
        run.undo()
        XCTAssertNil(run.pending)
        try run.grade(.recalled, repo: repo, at: StoreFixtures.now, nanos: 21_000_000)
        try run.next(repo: repo, nanos: 31_000_000)
        XCTAssertEqual(try repo.attempts(cardID: a.id).first?.elapsedMilliseconds, 20)
        try run.reveal(repo: repo)
        try run.grade(.again, repo: repo, at: StoreFixtures.now, nanos: 41_000_000)
        try run.interrupt(repo: repo, at: StoreFixtures.now, nanos: 51_000_000)
        XCTAssertNil(run.pending)
        run = try PracticeService.resume(repo: repo, session: XCTUnwrap(repo.session(id: run.session.id)), at: StoreFixtures.now.addingTimeInterval(-900), nanos: 2_000_000)
        XCTAssertTrue(run.session.isRevealed)
        try run.grade(.hard, repo: repo, at: StoreFixtures.now, nanos: 7_000_000)
        try run.next(repo: repo, nanos: 8_000_000)
        XCTAssertEqual(try repo.attempts(cardID: b.id).first?.elapsedMilliseconds, 5)
        XCTAssertEqual(run.session.status, .completed)
    }
}
