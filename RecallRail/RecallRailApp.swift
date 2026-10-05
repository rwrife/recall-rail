import SwiftUI
import RecallRailKit
import RecallStore

@main
struct RecallRailApp: App {
    /// The app-owned database is opened exactly once per process. Deck
    /// authoring and practice screens (later milestones) read and write
    /// through this repository; a failure to open is surfaced in the UI
    /// rather than silently swallowed — the app has no network fallback
    /// and no local storage means no function.
    let database: RecallRepository?
    let databaseFailure: String?
    /// One library per process: it holds the observable deck list and the
    /// write-through repository. Constructing it inside `body` would reset
    /// browsing state on every render.
    let library: DeckLibrary?

    init() {
        do {
            let repo = try AppDatabase.openShared()
            database = repo
            library = DeckLibrary(repo: repo)
            databaseFailure = nil
        } catch {
            database = nil
            library = nil
            databaseFailure = String(describing: error)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let library {
                ContentView(productName: RecallRailKit.productName,
                            databaseAvailable: true,
                            library: library)
            } else {
                ContentView(productName: RecallRailKit.productName,
                            databaseAvailable: false)
            }
        }
    }
}
