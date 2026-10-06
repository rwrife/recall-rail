import SwiftUI
import RecallRailKit
import UniformTypeIdentifiers

/// A deck's cards: add/edit/archive/reorder plus the strict CSV import
/// flow (pick → preview → explicit commit) and a CSV export.
struct DeckDetailView: View {
    @Bindable var library: DeckLibrary
    let deckID: StableID

    @State private var search = ""
    @State private var showingNewCard = false
    @State private var editingCard: Card?
    @State private var showingImport = false
    @State private var showingArchivedCards = false
    @State private var deletingCard: Card?
    @State private var confirmDelete = false

    private var deck: Deck? {
        library.decks.first { $0.id == deckID }
    }

    var body: some View {
        List {
            if let deck {
                Section {
                    NavigationLink("Practice") { PracticeView(repo: library.repo, deckID: deckID) }
                        .accessibilityIdentifier("deck-detail.practice")
                    Button("New card", systemImage: "plus") { showingNewCard = true }
                        .accessibilityIdentifier("deck-detail.new-card")
                    Button("Import CSV", systemImage: "square.and.arrow.down") { showingImport = true }
                        .accessibilityIdentifier("deck-detail.import-csv")
                }
                Section {
                    ForEach(library.cards(in: deck, matching: search)) { card in
                        Button {
                            editingCard = card
                        } label: {
                            CardRow(card: card)
                        }
                            .accessibilityIdentifier("card.edit.\(card.id.rawValue)")
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    library.setCardArchived(card, archived: true)
                                } label: {
                                    Label("Archive card", systemImage: "archivebox")
                                }
                                .tint(.brown)
                                Button(role: .destructive) {
                                    deletingCard = card
                                    confirmDelete = true
                                } label: {
                                    Label("Delete card", systemImage: "trash")
                                }
                            }
                    }
                    .onMove { source, destination in
                        if search.isEmpty {
                            library.moveCards(in: deck, from: source, to: destination)
                        }
                    }
                } header: { Text("Cards") }
                Button(showingArchivedCards ? "Hide archived cards" : "Show archived cards") {
                    showingArchivedCards.toggle()
                }
                if showingArchivedCards {
                    Section("Archived cards") {
                        ForEach(library.archivedCards(in: deck)) { card in
                            HStack {
                                Text(card.prompt)
                                Spacer()
                                Button("Restore") {
                                    library.setCardArchived(card, archived: false)
                                }
                                Button("Delete", role: .destructive) {
                                    deletingCard = card
                                    confirmDelete = true
                                }
                            }
                        }
                    }
                }
            }
            if let error = library.lastError {
                Text("Storage error: \(error)").foregroundStyle(.red)
            }
        }
        .searchable(text: $search, prompt: "Search cards")
        .navigationTitle(deck?.title ?? "Deck")
        .toolbar { EditButton() }
        .sheet(isPresented: $showingNewCard) {
            CardEditorSheet { draft in
                library.save(cardDraft: draft, deckID: deckID)
            }
        }
        .sheet(item: $editingCard) { card in
            CardEditorSheet(card: card) { draft in
                library.save(cardDraft: draft, deckID: deckID)
            }
        }
        .sheet(isPresented: $showingImport) {
            CSVImportSheet(library: library, deckID: deckID)
        }
        .confirmationDialog("Delete card permanently?", isPresented: $confirmDelete) {
            Button("Delete card", role: .destructive) {
                if let deletingCard { _ = library.deleteCard(deletingCard) }
                deletingCard = nil
            }
        } message: {
            Text("Cards with recorded attempts cannot be deleted. Archive to preserve history.")
        }
    }
}

struct CardRow: View {
    let card: Card

    var body: some View {
        VStack(alignment: .leading) {
            Text(card.prompt).font(.headline)
            Text(card.answer).font(.subheadline).foregroundStyle(.secondary)
            if !card.tags.isEmpty {
                Text(card.tags.joined(separator: ", ")).font(.caption2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Card \(card.prompt), answer \(card.answer)")
    }
}
