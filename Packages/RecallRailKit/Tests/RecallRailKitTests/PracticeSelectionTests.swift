import XCTest
@testable import RecallRailKit

final class PracticeSelectionTests: XCTestCase {
    func testMasteryUsesScheduleIdentityAfterWallClockMovesBackwards() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let deck = StableID()
        let card = StableID()
        let before = ScheduleState.initial(at: now, algorithmVersion: 1)
        let firstID = StableID()
        let secondID = StableID()
        let scheduler = LeitnerScheduler()
        let firstSchedule = try scheduler.apply(grade: .recalled, to: before, at: now, attemptID: firstID)
        let secondSchedule = try scheduler.apply(grade: .hard, to: firstSchedule, at: now.addingTimeInterval(-500), attemptID: secondID)
        let first = Attempt(id: firstID, cardID: card, deckID: deck, timestamp: now, monotonicStartNanos: 0, monotonicEndNanos: 1, grade: .recalled, mode: .tapReveal, beforeSchedule: before, afterSchedule: firstSchedule, algorithmVersion: 1)
        let second = Attempt(id: secondID, cardID: card, deckID: deck, timestamp: now.addingTimeInterval(-500), monotonicStartNanos: 2, monotonicEndNanos: 3, grade: .hard, mode: .tapReveal, beforeSchedule: firstSchedule, afterSchedule: secondSchedule, algorithmVersion: 1)
        let deriver = MasteryDeriver(scheduler: scheduler)
        XCTAssertEqual(deriver.derive(evidence: [.attempt(first), .attempt(second)], currentSchedule: secondSchedule, at: now), .learning)
        XCTAssertEqual(deriver.derive(evidence: [.attempt(first)], currentSchedule: secondSchedule, at: now), .insufficientEvidence)
    }

    func testDueBoundaryTagsAndFilterIntersectWithRehearsalOrder() throws {
        let now = Date(timeIntervalSince1970: 100)
        let deck = StableID()
        let a = Card(deckID: deck, prompt: "alpha", answer: "A", tags: ["exam"], sortOrder: 1, createdAt: now, updatedAt: now)
        let b = Card(deckID: deck, prompt: "beta", answer: "B", tags: ["exam"], createdAt: now, updatedAt: now)
        let c = Card(deckID: deck, prompt: "alpha", answer: "C", createdAt: now, updatedAt: now)
        let selection = PracticeSelection(dueOnly: true, tags: ["exam"], filter: "alpha", rehearsalOrder: [c.id, b.id, a.id])
        XCTAssertEqual(try selection.order(cards: [a,b,c], schedules: [a.id: .initial(at: now, algorithmVersion: 1)], at: now), [a.id])
        XCTAssertEqual(try selection.order(cards: [a,b,c], schedules: [a.id: .initial(at: now.addingTimeInterval(1), algorithmVersion: 1)], at: now), [])
    }
}
