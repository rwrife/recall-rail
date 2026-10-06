import Foundation
import Observation
import RecallRailKit
import RecallStore

/// In-memory deck/card browsing state backed by the transactional store.
///
/// Every mutation writes through `RecallRepository` first and refreshes the
/// in-memory lists from the store second, so the UI never shows state the
/// database did not durably accept. Search and tag filters are pure
/// in-memory refinements — they never hide an archived deck from the
/// "Archived" view or leak archived cards into the active list.
@MainActor
@Observable
final class DeckLibrary {
    let repo: RecallRepository
    private let clock: InstantProviding

    var decks: [Deck] = []
    var lastError: String?

    init(repo: RecallRepository, clock: InstantProviding = SystemClock()) {
        self.repo = repo
        self.clock = clock
        reload()
    }

    func reload() {
        do {
            decks = try repo.allDecks(includeArchived: true)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: Queries (pure refinements)

    var activeDecks: [Deck] { decks.filter { !$0.isArchived } }
    var archivedDecks: [Deck] { decks.filter(\.isArchived) }

    func decks(matching query: String) -> [Deck] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return activeDecks }
        return activeDecks.filter { deck in
            deck.title.lowercased().contains(needle)
                || deck.notes.lowercased().contains(needle)
                || deck.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    func cards(in deck: Deck, matching query: String) -> [Card] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let cards = (try? repo.cards(deckID: deck.id)) ?? []
        guard !needle.isEmpty else { return cards.sorted { $0.sortOrder < $1.sortOrder } }
        return cards.filter { card in
            card.prompt.lowercased().contains(needle)
                || card.answer.lowercased().contains(needle)
                || card.tags.contains { $0.lowercased().contains(needle) }
        }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func importExistingCards(deckID: StableID) throws -> [Card] {
        try repo.cards(deckID: deckID, includeArchived: true)
    }

    func archivedCards(in deck: Deck) -> [Card] {
        ((try? repo.cards(deckID: deck.id, includeArchived: true)) ?? [])
            .filter(\.isArchived)
    }

    /// Sort order for the next appended card in a deck.
    func nextSortOrder(in deckID: StableID) -> Int {
        let cards = (try? repo.cards(deckID: deckID, includeArchived: true)) ?? []
        return (cards.map(\.sortOrder).max() ?? -1) + 1
    }

    // MARK: Mutations (write-through)

    func save(draft: DeckDraft) -> Bool {
        guard let deck = draft.committedDeck(at: clock.now()) else { return false }
        do {
            if draft.original == nil {
                try repo.saveDeck(deck)
            } else {
                try repo.saveDeck(deck, preserveCreatedAt: true)
            }
            reload()
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    func save(cardDraft draft: CardDraft, deckID: StableID) -> Bool {
        let next = nextSortOrder(in: deckID)
        guard let card = draft.committedCard(deckID: deckID, nextSortOrder: next,
                                             at: clock.now()) else { return false }
        do {
            try repo.saveCard(card)
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    func deleteDeck(_ deck: Deck) -> Bool {
        do {
            try repo.deleteDeck(id: deck.id)
            reload()
            return true
        } catch {
            lastError = "Cannot delete deck with recorded study evidence. Archive it instead. \(error)"
            return false
        }
    }

    func deleteCard(_ card: Card) -> Bool {
        do {
            try repo.deleteCard(id: card.id)
            lastError = nil
            return true
        } catch {
            lastError = "Cannot delete card with recorded study evidence. Archive it instead. \(error)"
            return false
        }
    }

    func setDeckArchived(_ deck: Deck, archived: Bool) {
        do {
            try repo.setDeckArchived(id: deck.id, archived: archived, at: clock.now())
            reload()
        } catch {
            lastError = String(describing: error)
        }
    }

    func setCardArchived(_ card: Card, archived: Bool) {
        do {
            try repo.setCardArchived(id: card.id, archived: archived, at: clock.now())
        } catch {
            lastError = String(describing: error)
        }
    }

    func moveCards(in deck: Deck, from source: IndexSet, to destination: Int) {
        do {
            var cards = try repo.cards(deckID: deck.id)
            cards.move(fromOffsets: source, toOffset: destination)
            try repo.reorderCards(deckID: deck.id, orderedIDs: cards.map(\.id), at: clock.now())
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: CSV commit

    /// Commits a previously-previewed import. `validRowsOnly` must be an
    /// EXPLICIT user choice; the default stays all-or-nothing.
    ///
    /// The store re-validates the batch independently of the preview
    /// (duplicate IDs, unknown deck, cross-deck IDs), so rows the preview
    /// classified as valid can still be rejected here. Any rejection is
    /// surfaced in `lastError`; the caller keeps the preview visible.
    /// Returns nil on success.
    func commit(preview: CSVCardImport.Preview, deckID: StableID,
                validRowsOnly: Bool = false) -> String? {
        guard validRowsOnly ? preview.canCommitValidRowsOnly : preview.canCommitAllOrNothing,
              preview.documentIsValid, !preview.proposedRows.isEmpty else {
            return "Preview has errors or no importable rows; nothing was written."
        }
        let existing: [Card]
        do {
            existing = try importExistingCards(deckID: deckID)
        } catch {
            return "Could not read current cards; nothing was written: \(error)"
        }
        let materialized = CSVCardImport.cards(from: preview, deckID: deckID,
                                               existingCards: existing, at: clock.now())
        guard !materialized.isEmpty else { return nil } // nothing to write
        do {
            // Preview already excluded invalid file rows for an explicit
            // valid-rows-only choice. Keep the remaining batch atomic at
            // the database boundary: a new cross-deck collision must not
            // commit other cards and leave a retryable stale preview.
            let outcome = try repo.importCards(materialized, mode: .allOrNothing)
            if outcome.rejected.isEmpty {
                lastError = nil
                return nil // success
            }
            let reason = "\(outcome.rejected.count) row(s) rejected at commit: "
                + outcome.rejected.map(\.reason).joined(separator: "; ")
            lastError = reason
            return reason
        } catch {
            lastError = String(describing: error)
            return String(describing: error)
        }
    }

    func exportCSV(deckID: StableID) -> String {
        let cards = ((try? repo.cards(deckID: deckID, includeArchived: true)) ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
        return CSVCardImport.exportCSV(cards: cards)
    }
}
