import Foundation
import GRDB
import RecallStore

/// Owns the single app-owned database handle for the whole app process.
///
/// Decks, cards, schedules, attempts, and sessions live in one SQLite file
/// inside the app container (Application Support/RecallRail) — never in a
/// shared or cloud location. The store layer documents backup boundaries and
/// the reset contract; this type is the only place the app opens the file.
enum AppDatabase {
    /// Open (creating and migrating on first launch) the production
    /// database and return a ready repository.
    static func openShared() throws -> RecallRepository {
        let directory = try RecallDatabase.applicationDirectory()
        let url = RecallDatabase.databaseURL(in: directory)
        return RecallRepository(db: try RecallDatabase.open(at: url))
    }
}
