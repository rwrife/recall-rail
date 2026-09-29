import SwiftUI

struct ContentView: View {
    let productName: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(productName, systemImage: "rectangle.stack.fill")
            } description: {
                Text("Your private study decks will live here.")
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
