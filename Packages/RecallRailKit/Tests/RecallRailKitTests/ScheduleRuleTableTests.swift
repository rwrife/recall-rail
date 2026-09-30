import XCTest
@testable import RecallRailKit

/// Table-driven tests: every `(grade, box)` transition must match the
/// checked-in rule table exactly, with no implicit behavior.
final class ScheduleRuleTableTests: XCTestCase {

    func testVersion1TableIsWellFormed() {
        XCTAssertTrue(SchedulingRules.isWellFormed(version: 1))
        XCTAssertEqual(SchedulingRules.rows(version: 1).count, 18)
    }

    func testUnknownVersionHasNoRows() {
        XCTAssertTrue(SchedulingRules.rows(version: 0).isEmpty)
        XCTAssertTrue(SchedulingRules.rows(version: 99).isEmpty)
        XCTAssertFalse(SchedulingRules.isWellFormed(version: 99))
    }

    func testAgainAlwaysDropsToBoxOneImmediatelyDue() throws {
        for box in 1...SchedulingRules.maxBox {
            let state = ScheduleState(box: box, dueAt: Fixtures.now, algorithmVersion: 1)
            let after = try LeitnerScheduler().apply(
                grade: .again, to: state, at: Fixtures.now, attemptID: StableID()
            )
            XCTAssertEqual(after.box, 1, "again from box \(box) must reset to box 1")
            XCTAssertEqual(after.dueAt, Fixtures.now, "again must re-present immediately")
            XCTAssertEqual(after.consecutiveRecalls, 0)
        }
    }

    func testHardKeepsBoxAndDueTomorrow() throws {
        let scheduler = LeitnerScheduler()
        for box in 1...SchedulingRules.maxBox {
            let state = ScheduleState(box: box, dueAt: Fixtures.now, consecutiveRecalls: 3, algorithmVersion: 1)
            let after = try scheduler.apply(
                grade: .hard, to: state, at: Fixtures.now, attemptID: StableID()
            )
            XCTAssertEqual(after.box, box, "hard from box \(box) keeps the box")
            XCTAssertEqual(
                after.dueAt,
                Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: Fixtures.now)!,
                "hard is due one civil day later"
            )
            XCTAssertEqual(after.consecutiveRecalls, 0, "hard breaks the clean-recall streak")
        }
    }

    func testRecalledPromotesOneBoxCappedAtTopWithTargetInterval() throws {
        let expectedIntervals = SchedulingRules.v1BoxIntervalDays
        for box in 1...SchedulingRules.maxBox {
            let state = ScheduleState(box: box, dueAt: Fixtures.now, algorithmVersion: 1)
            let after = try LeitnerScheduler().apply(
                grade: .recalled, to: state, at: Fixtures.now, attemptID: StableID()
            )
            let target = min(box + 1, SchedulingRules.maxBox)
            XCTAssertEqual(after.box, target)
            let days = expectedIntervals[target - 1]
            XCTAssertEqual(
                after.dueAt,
                Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: Fixtures.now)!
            )
            XCTAssertEqual(after.consecutiveRecalls, 1)
        }
    }

    func testRecallStreakIncrementsAcrossSuccessiveRecalls() throws {
        var state = ScheduleState.initial(at: Fixtures.now, algorithmVersion: 1)
        let scheduler = LeitnerScheduler()
        for expectedStreak in 1...4 {
            state = try scheduler.apply(
                grade: .recalled, to: state, at: Fixtures.now, attemptID: StableID()
            )
            XCTAssertEqual(state.consecutiveRecalls, expectedStreak)
        }
    }

    func testRuleTableMatchesEveryApplication() throws {
        // Exhaustive table-driven check: apply() must equal the table row.
        let scheduler = LeitnerScheduler()
        for version in [1] {
            for row in SchedulingRules.rows(version: version) {
                let state = ScheduleState(box: row.fromBox, dueAt: Fixtures.now, algorithmVersion: version)
                let after = try scheduler.apply(
                    grade: row.grade, to: state, at: Fixtures.now, attemptID: StableID()
                )
                XCTAssertEqual(after.box, row.toBox)
                XCTAssertEqual(after.algorithmVersion, version)
                if row.intervalDays == 0 {
                    XCTAssertEqual(after.dueAt, Fixtures.now)
                } else {
                    XCTAssertGreaterThan(after.dueAt, Fixtures.now)
                }
            }
        }
    }

    func testUnsupportedVersionAndOffLadderBoxThrow() {
        let scheduler = LeitnerScheduler()
        let alien = ScheduleState(box: 2, dueAt: Fixtures.now, algorithmVersion: 42)
        XCTAssertThrowsError(
            try scheduler.apply(grade: .recalled, to: alien, at: Fixtures.now, attemptID: StableID())
        ) { error in
            XCTAssertEqual(error as? SchedulingError, .unsupportedAlgorithmVersion(42))
        }
        let offLadder = ScheduleState(box: 99, dueAt: Fixtures.now, algorithmVersion: 1)
        XCTAssertThrowsError(
            try scheduler.apply(grade: .recalled, to: offLadder, at: Fixtures.now, attemptID: StableID())
        ) { error in
            XCTAssertEqual(error as? SchedulingError, .boxOutOfRange(99))
        }
    }

    func testLastAttemptIDAndSnapshotsStoredOnAttempt() throws {
        let scheduler = LeitnerScheduler()
        let cardID = StableID()
        let deckID = StableID()
        let attemptID = StableID()
        let before = ScheduleState.initial(at: Fixtures.now, algorithmVersion: 1)
        let after = try scheduler.apply(grade: .recalled, to: before, at: Fixtures.now, attemptID: attemptID)
        XCTAssertEqual(after.lastAttemptID, attemptID)

        let monotonic = FakeMonotonic(start: 1_000_000)
        let attempt = Attempt(
            id: attemptID,
            cardID: cardID,
            deckID: deckID,
            timestamp: Fixtures.now,
            monotonicStartNanos: monotonic.nowNanoseconds(),
            monotonicEndNanos: { monotonic.advance(nanos: 4_500_000); return monotonic.nowNanoseconds() }(),
            grade: .recalled,
            mode: .tapReveal,
            beforeSchedule: before,
            afterSchedule: after,
            algorithmVersion: 1
        )
        XCTAssertEqual(attempt.elapsedMilliseconds, 4)
        XCTAssertEqual(attempt.beforeSchedule, before, "attempt stores its own before snapshot")
        XCTAssertEqual(attempt.afterSchedule, after, "attempt stores its own after snapshot")
    }

    func testEditingCardTextDoesNotRewriteHistoricalSnapshot() throws {
        // Attempts snapshot their own schedule state; mutating card content
        // (a separate value type) must not alter recorded evidence.
        let scheduler = LeitnerScheduler()
        let before = ScheduleState.initial(at: Fixtures.now, algorithmVersion: 1)
        let after = try scheduler.apply(grade: .again, to: before, at: Fixtures.now, attemptID: StableID())
        var card = Card(deckID: StableID(), prompt: "old", answer: "old", createdAt: Fixtures.now, updatedAt: Fixtures.now)
        let attempt = Attempt(
            cardID: card.id, deckID: card.deckID, timestamp: Fixtures.now,
            monotonicStartNanos: 0, monotonicEndNanos: 1_000_000,
            grade: .again, mode: .tapReveal, beforeSchedule: before, afterSchedule: after,
            algorithmVersion: 1
        )
        card.prompt = "edited"
        card.answer = "edited"
        XCTAssertEqual(attempt.beforeSchedule.dueAt, Fixtures.now)
        XCTAssertEqual(attempt.afterSchedule.box, 1)
    }
}
