import Foundation
import SwiftUI
import RecallRailKit
import RecallStore

/// Presentation state + validation vocabulary for authoring screens.
///
/// Every authoring form follows the same contract: edits happen on a
/// COPY, Save commits only when the copy validates, Cancel discards the
/// copy — closing a sheet without Save can never mutate stored state.
enum AuthoringValidation {
    /// User-facing validation issues with accessibility labels.
    struct Issue: Identifiable, Equatable {
        let id: String
        let label: String
    }

    static func deckIssues(title: String) -> [Issue] {
        var issues: [Issue] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(Issue(id: "deck.title.empty",
                                label: "Deck title is required."))
        }
        return issues
    }

    static func cardIssues(prompt: String, answer: String) -> [Issue] {
        var issues: [Issue] = []
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(Issue(id: "card.prompt.empty", label: "Prompt is required."))
        }
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(Issue(id: "card.answer.empty", label: "Answer is required."))
        }
        return issues
    }
}

/// Editable copy of a deck for the authoring sheet.
struct DeckDraft: Equatable {
    var original: Deck?
    var title: String
    var notes: String
    var tags: [String]

    init(deck: Deck? = nil, at instant: Date) {
        original = deck
        title = deck?.title ?? ""
        notes = deck?.notes ?? ""
        tags = deck?.tags ?? []
    }

    var validationIssues: [AuthoringValidation.Issue] {
        AuthoringValidation.deckIssues(title: title)
    }

    /// Produces the domain value to persist; nil when invalid. The clock
    /// arrives as a parameter so views stay deterministic in tests.
    func committedDeck(at instant: Date) -> Deck? {
        guard validationIssues.isEmpty else { return nil }
        var deck = original
        if deck == nil {
            deck = Deck(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        notes: notes, tags: tags,
                        createdAt: instant, updatedAt: instant)
        }
        deck?.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        deck?.notes = notes
        deck?.tags = tags
        deck?.updatedAt = instant
        return deck
    }
}

/// Editable copy of a card for the authoring sheet.
struct CardDraft: Equatable {
    var original: Card?
    var prompt: String
    var answer: String
    var hint: String
    var source: String
    var tags: [String]

    init(card: Card? = nil) {
        original = card
        prompt = card?.prompt ?? ""
        answer = card?.answer ?? ""
        hint = card?.hint ?? ""
        source = card?.source ?? ""
        tags = card?.tags ?? []
    }

    var validationIssues: [AuthoringValidation.Issue] {
        AuthoringValidation.cardIssues(prompt: prompt, answer: answer)
    }

    /// Produces the domain value; new cards get `sortOrder` appended to the
    /// deck's current maximum. Creation time is fixed at first commit.
    func committedCard(deckID: StableID, nextSortOrder: Int, at instant: Date) -> Card? {
        guard validationIssues.isEmpty else { return nil }
        func optionalized(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if var card = original {
            card.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            card.answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            card.hint = optionalized(hint)
            card.source = optionalized(source)
            card.tags = tags
            card.updatedAt = instant
            return card
        }
        return Card(deckID: deckID,
                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                    hint: optionalized(hint), source: optionalized(source), tags: tags,
                    sortOrder: nextSortOrder, createdAt: instant, updatedAt: instant)
    }
}
