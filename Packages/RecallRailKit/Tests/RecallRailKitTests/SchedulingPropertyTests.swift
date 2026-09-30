import XCTest
@testable import RecallRailKit

/// Property-style tests over a seeded deterministic PRNG: failures are
/// reproducible from the printed seed alone.
final class SchedulingPropertyTests: XCTestCase {

    private func makeSeededCases(count: Int, seed: UInt64) -> [(grade: Grade, box: Int, instant: Date)] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { _ in
            (grade: rng.grade(), box: rng.box(maxBox: SchedulingRules.maxBox), instant: rng.instant())
        }
    }

    func testEveryTransitionStaysOnLadderAndMovesForward() throws {
        let scheduler = LeitnerScheduler()
        for seed: UInt64 in [0x0123456789ABCDEF, 0xFEEDFACE, 42] {
            for c in makeSeededCases(count: 400, seed: seed) {
                let state = ScheduleState(box: c.box, dueAt: c.instant, algorithmVersion: 1)
                let after = try scheduler.apply(
                    grade: c.grade, to: state, at: c.instant, attemptID: StableID()
                )
                XCTAssertTrue(
                    (1...SchedulingRules.maxBox).contains(after.box),
                    "seed \(seed): box \(after.box) off ladder"
                )
                XCTAssertGreaterThanOrEqual(after.dueAt, c.instant, "seed \(seed): due moved backwards")
                XCTAssertGreaterThanOrEqual(after.consecutiveRecalls, 0)
                XCTAssertEqual(after.lastAttemptID?.rawValue.count, 36)
            }
        }
    }

    func testDeterminismSameInputSameOutput() throws {
        let scheduler = LeitnerScheduler()
        for c in makeSeededCases(count: 300, seed: 0xBADC0FFE) {
            let state = ScheduleState(box: c.box, dueAt: c.instant, consecutiveRecalls: 2, algorithmVersion: 1)
            let attemptID = StableID(rawValue: UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C0")!.uuidString)
            let first = try scheduler.apply(grade: c.grade, to: state, at: c.instant, attemptID: attemptID)
            let second = try scheduler.apply(grade: c.grade, to: state, at: c.instant, attemptID: attemptID)
            XCTAssertEqual(first, second)
        }
    }

    func testStreakMatchesConsecutiveRecalledSuffix() throws {
        // Property: after any grade sequence, consecutiveRecalls equals the
        // number of trailing .recalled grades (hard and again both break it).
        var rng = SplitMix64(seed: 0x5EEDBEAF)
        let scheduler = LeitnerScheduler()
        for _ in 0..<200 {
            var state = ScheduleState.initial(at: rng.instant(), algorithmVersion: 1)
            var grades: [Grade] = []
            let steps = 1 + Int(rng.below(14))
            for _ in 0..<steps {
                let grade = rng.grade()
                grades.append(grade)
                state = try scheduler.apply(grade: grade, to: state, at: rng.instant(), attemptID: StableID())
            }
            let expectedStreak = grades.reversed().prefix(while: { $0 == .recalled }).count
            XCTAssertEqual(state.consecutiveRecalls, expectedStreak,
                           "sequence \(grades.map(\.rawValue)) streak \(state.consecutiveRecalls) != \(expectedStreak)")
        }
    }

    func testAgainFromAnyBoxIsAlwaysDueImmediately() throws {
        let scheduler = LeitnerScheduler()
        var rng = SplitMix64(seed: 0xC0FFEE01)
        for _ in 0..<200 {
            let instant = rng.instant()
            let state = ScheduleState(box: rng.box(maxBox: SchedulingRules.maxBox), dueAt: instant, algorithmVersion: 1)
            let after = try scheduler.apply(grade: .again, to: state, at: instant, attemptID: StableID())
            XCTAssertEqual(after.dueAt, instant)
            XCTAssertEqual(after.box, 1)
        }
    }

    func testDeriverNeverClassifiesEmptyAsDueOrLearning() {
        let deriver = MasteryDeriver(scheduler: LeitnerScheduler())
        XCTAssertEqual(deriver.derive(evidence: [], at: Fixtures.now), .unseen)
        for junk in [
            [CardEvidence.skipped(id: StableID())],
            [.missing(id: StableID())],
            [.importedWithoutHistory(id: StableID())],
            [.corrupt(id: StableID())],
        ] {
            XCTAssertNotEqual(deriver.derive(evidence: junk, at: Fixtures.now), .due)
            XCTAssertNotEqual(deriver.derive(evidence: junk, at: Fixtures.now), .learning)
            XCTAssertNotEqual(deriver.derive(evidence: junk, at: Fixtures.now), .recentlyRecalled)
        }
    }

    func testDerivationOrderIndependent() {
        let deriver = MasteryDeriver(scheduler: LeitnerScheduler())
        let card = StableID()
        let deck = StableID()
        var rng = SplitMix64(seed: 0xD00D1234)
        for _ in 0..<100 {
            var evidence: [CardEvidence] = []
            for _ in 0..<5 {
                let instant = rng.instant()
                let dueOffset = Double(rng.below(200) &* 86_400) - 100 * 86_400
                let before = ScheduleState(box: rng.box(maxBox: SchedulingRules.maxBox), dueAt: instant, algorithmVersion: 1)
                let after = ScheduleState(box: rng.box(maxBox: SchedulingRules.maxBox),
                                          dueAt: instant.addingTimeInterval(dueOffset),
                                          lastAttemptID: StableID(), algorithmVersion: 1)
                evidence.append(.attempt(Attempt(
                    cardID: card, deckID: deck, timestamp: instant,
                    monotonicStartNanos: rng.next(), monotonicEndNanos: rng.next(),
                    grade: rng.grade(), mode: .tapReveal,
                    beforeSchedule: before, afterSchedule: after, algorithmVersion: 1
                )))
            }
            if rng.below(2) == 0 { evidence.append(.skipped(id: StableID())) }
            let shuffled = evidence.shuffled() // input order must not matter
            XCTAssertEqual(
                deriver.derive(evidence: evidence, at: Fixtures.now),
                deriver.derive(evidence: shuffled, at: Fixtures.now)
            )
        }
    }

    func testStableIDParsingRejectsGarbage() {
        XCTAssertNil(StableID(parsing: "not-a-uuid"))
        XCTAssertNil(StableID(parsing: ""))
        let uuid = UUID()
        XCTAssertEqual(StableID(parsing: uuid.uuidString)?.rawValue, uuid.uuidString)
    }
}
