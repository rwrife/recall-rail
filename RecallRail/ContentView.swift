import SwiftUI

/// Root view. With storage ready it hosts the deck library; a failed
/// open stays visible (no network fallback exists — no local storage
/// means no function).
struct ContentView: View {
    let productName: String
    /// False when the app-owned database could not be opened at launch.
    var databaseAvailable: Bool = true
    var library: DeckLibrary?

    var body: some View {
        if let library {
            NavigationStack {
                DeckListView(library: library)
            }
        } else {
            NavigationStack {
                ContentUnavailableView {
                    Label(productName, systemImage: "rectangle.stack.fill")
                } description: {
                    Text("Local storage could not be opened. Your decks are safe on this device but unavailable until storage is restored.")
                } actions: {
                    Button("Create a deck") {}
                        .disabled(true)
                        .accessibilityHint("Storage is unavailable.")
                }
                .navigationTitle(productName)
            }
        }
    }
}

#Preview {
    ContentView(productName: "Recall Rail")
}
