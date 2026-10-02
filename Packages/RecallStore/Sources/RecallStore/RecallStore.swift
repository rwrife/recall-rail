import Foundation

/// GRDB/SQLite persistence for Recall Rail.
///
/// All user data — decks, cards, schedules, attempts, sessions — lives in a
/// single app-owned database file. There is no cloud sync, account, network
/// storage, analytics, or tracking anywhere in this layer.
///
/// ## Database location
///
/// Production uses `RecallDatabase.applicationDirectory(...)` which places
/// `recallrail.sqlite` inside the app's Application Support container
/// (`.../Library/Application Support/RecallRail/recallrail.sqlite`). That
/// directory is included in the device backup by default; the app never
/// writes outside its own container.
///
/// ## Backup boundaries
///
/// The database file (plus its WAL/SHM sidecars) is the complete state of
/// the app. Versioned JSON backup/restore is delivered separately; until
/// then an iTunes/Finder device backup of the app container is the only
/// supported copy of the data.
///
/// ## What reset deletes
///
/// `RecallRepository.resetAll()` erases every row — decks, cards, schedule
/// state, attempt ledger, skips, and sessions — inside one transaction that
/// atomically drops and re-creates the append-only DELETE triggers, so
/// evidence is never committed unprotected. `deleteAllData(at:)` additionally
/// closes the connection and unlinks the database file and sidecars via
/// `RecallDatabase.unlinkDatabase(at:)`. Reset is irreversible and matches
/// the user-facing "delete all my data" promise.
public enum RecallStore {
    public static let domain = "RecallStore"
    /// Schema version shipped by `RecallDatabaseMigrator`.
    public static let schemaVersion = 3
}
