import SwiftUI
import RecallRailKit

/// Local deck library with explicit create/edit/archive/restore actions.
struct DeckListView: View {
    @Bindable var library: DeckLibrary
    @State private var search = ""
    @State private var showingNewDeck = false
    @State private var showingArchived = false
    @State private var editingDeck: Deck?

    var body: some View {
        List {
            if library.activeDecks.isEmpty {
                ContentUnavailableView("No active decks", systemImage: "rectangle.stack",
                                       description: Text("Create a deck or restore an archived deck."))
            }
            Section("Decks") {
                ForEach(library.decks(matching: search)) { deck in
                    NavigationLink {
                        DeckDetailView(library: library, deckID: deck.id)
                    } label: {
                        DeckRow(deck: deck)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Archive", systemImage: "archivebox") {
                            library.setDeckArchived(deck, archived: true)
                        }
                        .tint(.brown)
                        Button("Edit", systemImage: "pencil") { editingDeck = deck }
                    }
                    .accessibilityIdentifier("deck-row.\(deck.id.rawValue)")
                }
            }
            if showingArchived {
                Section("Archived decks") {
                    ForEach(library.archivedDecks) { deck in
                        HStack {
                            DeckRow(deck: deck)
                            Spacer()
                            Button("Restore") {
                                library.setDeckArchived(deck, archived: false)
                            }
                            .accessibilityIdentifier("deck.restore.\(deck.id.rawValue)")
                        }
                    }
                }
            }
            if let error = library.lastError {
                Text("Storage error: \(error)").foregroundStyle(.red)
                    .accessibilityIdentifier("deck.storage-error")
            }
        }
        .searchable(text: $search, prompt: "Search decks and tags")
        .navigationTitle("Recall Rail")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(showingArchived ? "Hide archived" : "Show archived") {
                    showingArchived.toggle()
                }
                .accessibilityIdentifier("deck-list.archived")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewDeck = true
                } label: {
                    Label("Create a deck", systemImage: "plus")
                }
                .accessibilityIdentifier("deck-list.create")
            }
        }
        .sheet(isPresented: $showingNewDeck) {
            DeckEditorSheet { draft in library.save(draft: draft) }
        }
        .sheet(item: $editingDeck) { deck in
            DeckEditorSheet(deck: deck) { draft in library.save(draft: draft) }
        }
        .onAppear { library.reload() }
    }
}

struct DeckRow: View {
    let deck: Deck

    var body: some View {
        VStack(alignment: .leading) {
            Text(deck.title).font(.headline)
            Text("\(deck.notes.isEmpty ? "" : deck.notes + " · ")\(deck.tags.isEmpty ? "no tags" : deck.tags.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
