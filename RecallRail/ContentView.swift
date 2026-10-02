import SwiftUI

struct ContentView: View {
    let productName: String
    /// False when the app-owned database could not be opened at launch.
    /// Until authoring screens land, a failed open is the only state the
    /// learner can observe, so it must be visible rather than silent.
    var databaseAvailable: Bool = true

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(productName, systemImage: "rectangle.stack.fill")
            } description: {
                if databaseAvailable {
                    Text("Your private study decks will live here.")
                } else {
                    Text("Local storage could not be opened. Your decks are safe on this device but unavailable until storage is restored.")
                }
            } actions: {
                Button("Create a deck") {}
                    .disabled(true)
                    .accessibilityHint("Deck authoring arrives in a later milestone.")
            }
            .navigationTitle(productName)
        }
    }
}

#Preview {
    ContentView(productName: "Recall Rail")
}
