import Foundation

/// All refinements intersect. Explicit rehearsal order is a subset in the
/// user's order; otherwise authoring order has a stable ID tie-break.
public struct PracticeSelection: Sendable {
    public var dueOnly: Bool
    public var tags: Set<String>
    public var filter: String
    public var rehearsalOrder: [StableID]?

    public init(dueOnly: Bool = false, tags: Set<String> = [], filter: String = "", rehearsalOrder: [StableID]? = nil) {
        self.dueOnly = dueOnly
        self.tags = tags
        self.filter = filter
        self.rehearsalOrder = rehearsalOrder
    }

    public func order(cards: [Card], schedules: [StableID: ScheduleState], at instant: Date) throws -> [StableID] {
        for schedule in schedules.values { try LeitnerScheduler().validate(schedule) }
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let eligible = cards.filter { card in
            !card.isArchived && tags.isSubset(of: Set(card.tags))
                && (needle.isEmpty || [card.prompt, card.answer, card.tags.joined(separator: " ")].contains { $0.lowercased().contains(needle) })
                && (!dueOnly || schedules[card.id].map { instant >= $0.dueAt } ?? true)
        }
        if let rehearsalOrder {
            guard Set(rehearsalOrder).count == rehearsalOrder.count,
                  Set(rehearsalOrder).isSubset(of: Set(cards.map(\.id))) else {
                throw PracticeError.invalidOrder
            }
            let ids = Set(eligible.map(\.id))
            return rehearsalOrder.filter { ids.contains($0) }
        }
        return eligible.sorted {
            $0.sortOrder == $1.sortOrder ? $0.id.rawValue < $1.id.rawValue : $0.sortOrder < $1.sortOrder
        }.map(\.id)
    }
}

public enum PracticeError: Error, Equatable, Sendable {
    case invalidOrder, emptyQueue, noCurrentCard, revealRequired, pendingRequired, staleSession, missingScheduleEvidence
}
