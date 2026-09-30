import XCTest
@testable import RecallRailKit

/// Clock semantics: injected clock only, DST-safe civil-day scheduling, and
/// locale-boundary stability.
final class ClockAndDSTTests: XCTestCase {

    func testSchedulerUsesInjectedCalendarNotSystemZone() throws {
        // UTC calendar: +1 day from noon UTC is exactly 24h later.
        let utcScheduler = LeitnerScheduler()
        let state = ScheduleState(box: 2, dueAt: Fixtures.now, algorithmVersion: 1)
        let inUTC = try utcScheduler.apply(grade: .hard, to: state, at: Fixtures.now, attemptID: StableID())
        XCTAssertEqual(inUTC.dueAt.timeIntervalSince(Fixtures.now), 24 * 3600, accuracy: 1)

        // New York calendar at the same instant gives the same absolute due
        // time in non-DST weeks: civil-day math is zone-anchored, not
        // machine-zone dependent.
        var nyCal = Calendar(identifier: .gregorian)
        nyCal.timeZone = Fixtures.ny
        let nyScheduler = LeitnerScheduler(calendar: nyCal)
        let inNY = try nyScheduler.apply(grade: .hard, to: state, at: Fixtures.now, attemptID: StableID())
        XCTAssertLessThanOrEqual(abs(inNY.dueAt.timeIntervalSince(inUTC.dueAt)), 1)
    }

    func testHardAcrossSpringForwardKeepsWallClockTime() throws {
        // 2026-03-08T07:30:00Z is Sunday 03:30 EDT, after spring-forward.
        // +1 civil day lands Monday 03:30 EDT = 2026-03-09T07:30:00Z.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Fixtures.ny
        let scheduler = LeitnerScheduler(calendar: cal)
        let state = ScheduleState(box: 3, dueAt: Fixtures.dstSpringForwardNY, algorithmVersion: 1)
        let after = try scheduler.apply(
            grade: .hard, to: state, at: Fixtures.dstSpringForwardNY, attemptID: StableID()
        )
        XCTAssertEqual(Fixtures.instant("2026-03-09T07:30:00Z"), after.dueAt,
                       "civil day after spring-forward keeps 03:30 wall time")
        // Absolute interval is 24 hours because the transition already
        // happened before the anchor instant — no silent 23/25h drift.
        XCTAssertEqual(after.dueAt.timeIntervalSince(Fixtures.dstSpringForwardNY), 24 * 3600, accuracy: 1)
    }

    func testDueComparisonAcrossFallBackIsAbsolute() throws {
        // Around fall-back, wall clock repeats but instants do not. A card
        // due at 05:30Z must still read not-due at 04:30Z an hour earlier,
        // and due an hour later — regardless of the repeated 01:30 wall time.
        let scheduler = LeitnerScheduler()
        let state = ScheduleState(
            box: 4, dueAt: Fixtures.dstFallBackNY,
            lastAttemptID: StableID(), algorithmVersion: 1
        )
        let earlier = Fixtures.dstFallBackNY.addingTimeInterval(-3600)
        let later = Fixtures.dstFallBackNY.addingTimeInterval(3600)
        XCTAssertEqual(scheduler.dueReason(for: state, at: earlier).kind, .notDue)
        XCTAssertEqual(scheduler.dueReason(for: state, at: Fixtures.dstFallBackNY).kind, .dueElapsed)
        XCTAssertEqual(scheduler.dueReason(for: state, at: later).kind, .dueElapsed)
    }

    func testRecallIntervalsLandOnExpectedInstantsInLocalZone() throws {
        // A card graded 2026-10-31T05:30:00Z (Saturday 01:30 EDT) with a
        // recall from box 5 promotes to box 6, whose arrival interval is 35
        // civil days — landing across the fall-back transition. Civil-day
        // math keeps the 01:30 wall time (EDT anchor becomes EST result),
        // which is 06:30Z after the shift.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Fixtures.ny
        let scheduler = LeitnerScheduler(calendar: cal)
        let state = ScheduleState(box: 5, dueAt: Fixtures.beforeFallBackNY, algorithmVersion: 1)
        let after = try scheduler.apply(
            grade: .recalled, to: state, at: Fixtures.beforeFallBackNY, attemptID: StableID()
        )
        XCTAssertEqual(after.box, 6)
        let expected = cal.date(byAdding: .day, value: 35, to: Fixtures.beforeFallBackNY)!
        XCTAssertEqual(after.dueAt, expected)
        XCTAssertEqual(after.dueAt, Fixtures.instant("2026-12-05T06:30:00Z"),
                       "35 civil days from 01:30 EDT lands at 01:30 EST")
        let dayDelta = cal.dateComponents([.day], from: cal.startOfDay(for: Fixtures.beforeFallBackNY), to: cal.startOfDay(for: after.dueAt)).day
        XCTAssertEqual(dayDelta, 35)
    }

    func testClockProtocolIsInjectable() {
        let clock = FakeClock(instant: Fixtures.now)
        XCTAssertEqual(clock.now(), Fixtures.now)
    }

    func testMonotonicElapsedIsImmuneToWallClockChange() {
        // Session elapsed time must come from monotonic anchors. A wall
        // clock rewound by an NTP correction cannot fake shorter study time.
        let monotonic = FakeMonotonic(start: 10_000_000_000)
        var session = StudySession(
            deckID: StableID(), cardOrder: [], mode: .tapReveal,
            startedAt: Fixtures.now, monotonicStartNanos: monotonic.nowNanoseconds(),
            monotonicCheckpointNanos: monotonic.nowNanoseconds()
        )
        monotonic.advance(nanos: 60_000_000_000) // 60 real seconds
        let wallAfterRewind = Fixtures.now.addingTimeInterval(-86_400) // user sets clock back a day
        session.monotonicCheckpointNanos = monotonic.nowNanoseconds()
        let elapsed = session.monotonicCheckpointNanos - session.monotonicStartNanos
        XCTAssertEqual(elapsed, 60_000_000_000)
        XCTAssertLessThan(wallAfterRewind, session.startedAt,
                          "wall clock moved backwards; monotonic elapsed still says 60s")
    }
}
