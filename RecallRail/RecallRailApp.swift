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

    init() {
        do {
            database = try AppDatabase.openShared()
            databaseFailure = nil
        } catch {
            database = nil
            databaseFailure = String(describing: error)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(productName: RecallRailKit.productName,
                        databaseAvailable: database != nil)
        }
    }
}
