import XCTest
@testable import RecallRailKit

final class PracticeSelectionTests: XCTestCase {
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
