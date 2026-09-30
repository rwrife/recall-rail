import Foundation

/// A user-authored deck of prompts.
///
/// Timestamps are wall-clock instants supplied by an injected clock so that
/// domain construction never reads `Date()` internally.
public struct Deck: Codable, Equatable, Identifiable, Sendable {
    public let id: StableID
    public var title: String
    public var notes: String
    public var tags: [String]
    public var isArchived: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: StableID = StableID(),
        title: String,
        notes: String = "",
        tags: [String] = [],
        isArchived: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.tags = tags
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A single prompt card inside a deck.
public struct Card: Codable, Equatable, Identifiable, Sendable {
    public let id: StableID
    public let deckID: StableID
    public var prompt: String
    public var answer: String
    public var hint: String?
    public var source: String?
    public var tags: [String]
    /// Stable user-defined ordering. Never derived from attempt history.
    public var sortOrder: Int
    public var isArchived: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: StableID = StableID(),
        deckID: StableID,
        prompt: String,
        answer: String,
        hint: String? = nil,
        source: String? = nil,
        tags: [String] = [],
        sortOrder: Int = 0,
        isArchived: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.deckID = deckID
        self.prompt = prompt
        self.answer = answer
        self.hint = hint
        self.source = source
        self.tags = tags
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
