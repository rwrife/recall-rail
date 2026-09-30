import XCTest
@testable import RecallRailKit

/// Unknown-safe mastery: skipped, missing, imported-without-history, and
/// corrupt evidence must never count as recalled or failed.
final class MasteryDerivationTests: XCTestCase {

    private var deriver: MasteryDeriver!
    private let cardID = StableID()
    private let deckID = StableID()

    override func setUp() {
        super.setUp()
        deriver = MasteryDeriver(scheduler: LeitnerScheduler())
    }

    private func makeAttempt(
        grade: Grade,
        at instant: Date,
        box: Int = 2,
        dueOffsetDays: TimeInterval = 60 * 86_400
    ) -> Attempt {
        let before = ScheduleState(box: box, dueAt: instant, algorithmVersion: 1)
        let after = ScheduleState(
            box: box, dueAt: instant.addingTimeInterval(dueOffsetDays),
            consecutiveRecalls: grade == .recalled ? 1 : 0,
            lastAttemptID: StableID(), algorithmVersion: 1
        )
        return Attempt(
            cardID: cardID, deckID: deckID, timestamp: instant,
            monotonicStartNanos: 0, monotonicEndNanos: 500_000_000,
            grade: grade, mode: .tapReveal,
            beforeSchedule: before, afterSchedule: after, algorithmVersion: 1
        )
    }

    func testEmptyEvidenceIsUnseen() {
        XCTAssertEqual(deriver.derive(evidence: [], at: Fixtures.now), .unseen)
    }

    func testSkippedOnlyIsInsufficientNeverFailed() {
        let state = deriver.derive(evidence: [.skipped(id: StableID())], at: Fixtures.now)
        XCTAssertEqual(state, .insufficientEvidence)
    }

    func testImportedWithoutHistoryIsInsufficient() {
        let state = deriver.derive(evidence: [.importedWithoutHistory(id: StableID())], at: Fixtures.now)
        XCTAssertEqual(state, .insufficientEvidence)
    }

    func testMissingRowIsInsufficient() {
        let state = deriver.derive(evidence: [.missing(id: StableID())], at: Fixtures.now)
        XCTAssertEqual(state, .insufficientEvidence)
    }

    func testCorruptRowIsInsufficient() {
        let state = deriver.derive(evidence: [.corrupt(id: StableID())], at: Fixtures.now)
        XCTAssertEqual(state, .insufficientEvidence)
    }

    func testMixedJunkWithNoReadableAttemptIsInsufficient() {
        let evidence: [CardEvidence] = [
            .skipped(id: StableID()), .corrupt(id: StableID()),
            .importedWithoutHistory(id: StableID()), .missing(id: StableID()),
        ]
        XCTAssertEqual(deriver.derive(evidence: evidence, at: Fixtures.now), .insufficientEvidence)
    }

    func testDueWhenLatestSnapshotElapsed() {
        let attempt = makeAttempt(grade: .again, at: Fixtures.now.addingTimeInterval(-7 * 86_400), dueOffsetDays: -86_400)
        XCTAssertEqual(
            deriver.derive(evidence: [.attempt(attempt)], at: Fixtures.now),
            .due
        )
    }

    func testRecentlyRecalledWhenNotDueAndLastWasRecalled() {
        let attempt = makeAttempt(grade: .recalled, at: Fixtures.now.addingTimeInterval(-3600))
        XCTAssertEqual(
            deriver.derive(evidence: [.attempt(attempt)], at: Fixtures.now),
            .recentlyRecalled
        )
    }

    func testLearningWhenNotDueAndLastWasHardOrAgain() {
        let hard = makeAttempt(grade: .hard, at: Fixtures.now.addingTimeInterval(-3600))
        XCTAssertEqual(deriver.derive(evidence: [.attempt(hard)], at: Fixtures.now), .learning)
        let again = makeAttempt(grade: .again, at: Fixtures.now.addingTimeInterval(-3600), dueOffsetDays: -86_400)
        // again with elapsed due window would be .due — push due forward to
        // exercise the learning branch.
        let againLaterDue = Attempt(
            cardID: cardID, deckID: deckID, timestamp: again.timestamp,
            monotonicStartNanos: 0, monotonicEndNanos: 1,
            grade: .again, mode: .tapReveal,
            beforeSchedule: again.beforeSchedule,
            afterSchedule: ScheduleState(box: 1, dueAt: Fixtures.now.addingTimeInterval(3600), algorithmVersion: 1),
            algorithmVersion: 1
        )
        XCTAssertEqual(deriver.derive(evidence: [.attempt(againLaterDue)], at: Fixtures.now), .learning)
    }

    func testCorruptLatestRowCannotMasqueradeAsRecalled() {
        // Old readable recall + newer corrupt row: the readable evidence
        // still drives derivation; the corrupt row is ignored, not treated
        // as a fresh grade.
        let recall = makeAttempt(grade: .recalled, at: Fixtures.now.addingTimeInterval(-2 * 86_400))
        let state = deriver.derive(
            evidence: [.attempt(recall), .corrupt(id: StableID())], at: Fixtures.now
        )
        XCTAssertEqual(state, .recentlyRecalled)
    }

    func testUnreadableSnapshotIsFilteredNotGraded() {
        // An attempt whose snapshot is off the ladder (simulated corruption
        // that decoded successfully) must derive insufficient, never due.
        let bogus = Attempt(
            cardID: cardID, deckID: deckID, timestamp: Fixtures.now,
            monotonicStartNanos: 0, monotonicEndNanos: 1,
            grade: .recalled, mode: .tapReveal,
            beforeSchedule: ScheduleState(box: 1, dueAt: Fixtures.now, algorithmVersion: 1),
            afterSchedule: ScheduleState(box: 77, dueAt: Fixtures.now, algorithmVersion: 1),
            algorithmVersion: 1
        )
        XCTAssertEqual(deriver.derive(evidence: [.attempt(bogus)], at: Fixtures.now), .insufficientEvidence)
    }

    func testUnknownAlgorithmVersionAttemptIsInsufficient() {
        let future = Attempt(
            cardID: cardID, deckID: deckID, timestamp: Fixtures.now,
            monotonicStartNanos: 0, monotonicEndNanos: 1,
            grade: .recalled, mode: .tapReveal,
            beforeSchedule: ScheduleState(box: 1, dueAt: Fixtures.now, algorithmVersion: 7),
            afterSchedule: ScheduleState(box: 2, dueAt: Fixtures.now, algorithmVersion: 7),
            algorithmVersion: 7
        )
        XCTAssertEqual(deriver.derive(evidence: [.attempt(future)], at: Fixtures.now), .insufficientEvidence)
    }

    func testEvidenceOrderingIsDeterministicUnderTimestampTies() {
        let a = makeAttempt(grade: .recalled, at: Fixtures.now)
        let b = Attempt(
            id: StableID(), cardID: cardID, deckID: deckID, timestamp: Fixtures.now,
            monotonicStartNanos: 999, monotonicEndNanos: 1000,
            grade: .again, mode: .tapReveal,
            beforeSchedule: a.beforeSchedule, afterSchedule: a.afterSchedule, algorithmVersion: 1
        )
        // Same timestamp — monotonic anchor breaks the tie, then ID.
        let forward = MasteryDeriver.orderedEvidence([.attempt(a), .attempt(b)])
        let backward = MasteryDeriver.orderedEvidence([.attempt(b), .attempt(a)])
        XCTAssertEqual(forward.map(\.id), backward.map(\.id), "ordering must be input-order independent")
    }
}
