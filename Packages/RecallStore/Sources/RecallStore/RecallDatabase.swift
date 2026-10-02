import Foundation
import GRDB

/// Errors the store raises for constraint violations the caller must react
/// to, as opposed to raw SQLite leakage.
public enum StoreError: Error, Equatable {
    /// An insert would overwrite an existing row outside an explicit save.
    case alreadyExists(String)
    /// A foreign-key violation (e.g. card whose deck does not exist).
    case foreignKeyFailed(detail: String)
    /// An append-only evidence table rejected an UPDATE/DELETE.
    case appendOnlyProtected(detail: String)
    /// The caller tried to record an attempt against a session that cannot
    /// accept it (not active, or the card is not the session's current one).
    case invalidSessionAdvance(String)
    /// A row could not be decomposed into domain records; the caller must
    /// map it to `CardEvidence.corrupt` rather than guessing a value.
    case corruptRow(table: String, id: String)
    /// The import/restore transaction was rolled back because a prepared
    /// operation failed midway. Carries the underlying error for reporting.
    case rolledBack(reason: String)
}

/// Open, migrate, and manage the app-owned SQLite database.
public enum RecallDatabase {
    /// Production location: Application Support inside the app container.
    /// See `RecallStore` docs for the backup-boundary contract.
    public static func applicationDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("RecallRail", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func databaseURL(in directory: URL) -> URL {
        directory.appendingPathComponent("recallrail.sqlite")
    }

    /// Open (creating if necessary) and migrate the database at `url`.
    public static func open(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try RecallDatabaseMigrator.migrator.migrate(queue)
        return queue
    }

    /// In-memory database for tests and previews.
    public static func openInMemory() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try RecallDatabaseMigrator.migrator.migrate(queue)
        return queue
    }

    /// Irreversibly delete the database and WAL/SHM sidecars ("delete all
    /// my data" reset). The caller must CLOSE the connection first — this
    /// only unlinks files; it does not know about open handles. The
    /// trigger-safe row erasure lives in `RecallRepository.resetAll`.
    public static func unlinkDatabase(at url: URL, fileManager: FileManager = .default) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
        }
    }

    /// Run `body` inside one transaction; a throw rolls every write back.
    public static func inTransaction(_ db: DatabaseWriter, _ body: (Database) throws -> Void) throws {
        try db.write { raw in
            try raw.inSavepoint {
                try body(raw)
                return .commit
            }
        }
    }

    static func mapSQLError(_ error: Error, table: String, id: String) -> Error {
        if let databaseError = error as? DatabaseError {
            let message = databaseError.message ?? String(describing: error)
            if message.localizedCaseInsensitiveContains("foreign key") {
                return StoreError.foreignKeyFailed(detail: message)
            }
            if message.localizedCaseInsensitiveContains("append-only") {
                return StoreError.appendOnlyProtected(detail: message)
            }
            if message.contains("UNIQUE constraint failed") {
                return StoreError.alreadyExists("\(table):\(id)")
            }
            return databaseError
        }
        return error
    }
}
