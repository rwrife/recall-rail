import Foundation
import GRDB
@testable import RecallRailKit
@testable import RecallStore

/// Shared helpers for the store test suite.
enum StoreFixtures {
    static let now = Date(timeIntervalSince1970: 1_775_000_000)

    static func deck(title: String = "Orgo 101") -> Deck {
        Deck(title: title, createdAt: now, updatedAt: now)
    }

    static func card(deckID: StableID, prompt: String = "Mitochondria?",
                     answer: String = "Powerhouse", sortOrder: Int = 0) -> Card {
        Card(deckID: deckID, prompt: prompt, answer: answer,
             sortOrder: sortOrder, createdAt: now, updatedAt: now)
    }

    static func attempt(card: Card, grade: Grade, at instant: Date = now,
                        start: UInt64 = 1_000, end: UInt64 = 2_500) throws -> Attempt {
        let scheduler = LeitnerScheduler()
        let before = ScheduleState.initial(at: instant, algorithmVersion: 1)
        let after = try scheduler.apply(grade: grade, to: before, at: instant,
                                        attemptID: StableID())
        return Attempt(cardID: card.id, deckID: card.deckID, timestamp: instant,
                       monotonicStartNanos: start, monotonicEndNanos: end,
                       grade: grade, mode: .tapReveal,
                       beforeSchedule: before, afterSchedule: after, algorithmVersion: 1)
    }
}

extension DatabaseQueue {
    /// Execute raw SQL bypassing the repository (for fixture surgery).
    func rawExecute(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws {
        try write { raw in try raw.execute(sql: sql, arguments: arguments) }
    }

    func rawInt(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> Int {
        try read { raw in try Int.fetchOne(raw, sql: sql, arguments: arguments) ?? -1 }
    }
}
