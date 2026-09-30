import XCTest
@testable import RecallRailKit

/// Interruption-safe session behavior: cursor, order, and anchors survive
/// interrupt/resume; completion is derived from the cursor, not guesses.
final class SessionResumeTests: XCTestCase {

    func testCurrentCardAndAdvanceFollowCursor() {
        let order = [StableID(), StableID(), StableID()]
        var session = StudySession(
            deckID: StableID(), cardOrder: order, mode: .tapReveal,
            startedAt: Fixtures.now, monotonicStartNanos: 0, monotonicCheckpointNanos: 0
        )
        XCTAssertEqual(session.currentCardID, order[0])
        session.advance()
        XCTAssertEqual(session.currentCardID, order[1])
        session.advance()
        session.advance()
        XCTAssertNil(session.currentCardID)
        XCTAssertEqual(session.status, .completed)
    }

    func testInterruptResumePreservesIdentityCursorAndOrder() {
        let id = StableID()
        let order = [StableID(), StableID()]
        var session = StudySession(
            id: id, deckID: StableID(), cardOrder: order, cursor: 1, mode: .spoken,
            startedAt: Fixtures.now, monotonicStartNanos: 100, monotonicCheckpointNanos: 100
        )
        let resumeInstant = Fixtures.now.addingTimeInterval(5 * 3600)
        session.interrupt(at: Fixtures.now.addingTimeInterval(60), monotonicNanos: 500)
        XCTAssertEqual(session.status, .interrupted)
        XCTAssertEqual(session.endedAt, Fixtures.now.addingTimeInterval(60))
        session.resume(at: resumeInstant, monotonicNanos: 900)
        XCTAssertEqual(session.id, id, "resume keeps the same session ID")
        XCTAssertEqual(session.cursor, 1, "the card in front of the learner is preserved")
        XCTAssertEqual(session.cardOrder, order, "order never re-derives")
        XCTAssertNil(session.endedAt)
        XCTAssertEqual(session.currentCardID, order[1])
    }

    func testAdvanceIsNoOpWhenNotActive() {
        var session = StudySession(
            deckID: StableID(), cardOrder: [StableID()], mode: .tapReveal,
            startedAt: Fixtures.now, monotonicStartNanos: 0, monotonicCheckpointNanos: 0
        )
        session.interrupt(at: Fixtures.now, monotonicNanos: 1)
        let before = session.cursor
        session.advance()
        XCTAssertEqual(session.cursor, before, "interrupted sessions do not advance")
    }

    func testSessionRoundTripsThroughCodable() throws {
        // The persistence layer (issue #3) relies on the session encoding
        // completely; assert the whole value survives JSON.
        let order = [StableID(), StableID(), StableID()]
        var session = StudySession(
            deckID: StableID(), cardOrder: order, cursor: 2, mode: .spoken,
            startedAt: Fixtures.now, monotonicStartNanos: 7, monotonicCheckpointNanos: 11
        )
        session.interrupt(at: Fixtures.now.addingTimeInterval(30), monotonicNanos: 40)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(StudySession.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    func testAttemptRoundTripsThroughCodable() throws {
        let scheduler = LeitnerScheduler()
        let before = ScheduleState.initial(at: Fixtures.now, algorithmVersion: 1)
        let after = try scheduler.apply(grade: .hard, to: before, at: Fixtures.now, attemptID: StableID())
        let attempt = Attempt(
            cardID: StableID(), deckID: StableID(), timestamp: Fixtures.now,
            monotonicStartNanos: 3, monotonicEndNanos: 4,
            grade: .hard, mode: .spoken, beforeSchedule: before, afterSchedule: after,
            algorithmVersion: 1
        )
        let data = try JSONEncoder().encode(attempt)
        let decoded = try JSONDecoder().decode(Attempt.self, from: data)
        XCTAssertEqual(decoded, attempt)
    }

    func testClockChangeBetweenInterruptAndResumeDoesNotMoveCursor() {
        var session = StudySession(
            deckID: StableID(), cardOrder: [StableID(), StableID()], cursor: 0, mode: .tapReveal,
            startedAt: Fixtures.now, monotonicStartNanos: 1_000, monotonicCheckpointNanos: 1_000
        )
        session.interrupt(at: Fixtures.now, monotonicNanos: 2_000)
        // Wall clock jumps forward a week while the device is off.
        session.resume(at: Fixtures.now.addingTimeInterval(7 * 86_400), monotonicNanos: 2_050)
        XCTAssertEqual(session.cursor, 0)
        // Monotonic gap is 50us — no phantom 7-hour study credit.
        let gap = session.monotonicCheckpointNanos - session.monotonicStartNanos
        XCTAssertEqual(gap, 1_050)
    }
}
