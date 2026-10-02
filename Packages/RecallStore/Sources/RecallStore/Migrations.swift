import Foundation
import GRDB

/// Ordered, forward-only migrations for the app-owned SQLite database.
///
/// v1 is the initial schema; v2 adds query indexes; v3 pins evidenced
/// cards to their deck. Migrations are replayed on every open through
/// GRDB's `DatabaseMigrator`, which is idempotent: applied versions are
/// recorded in `grdb_migration` and never run again.
///
/// Integrity rules encoded in the schema:
/// - Foreign keys are enforced by the connection (`foreignKeysEnabled`).
/// - Attempts and skips are append-only evidence: SQL triggers abort any
///   UPDATE or DELETE on those tables, so editing or deleting cards and
///   decks can never rewrite recorded history.
/// - Deck and card hard deletes are `RESTRICT`ed while attempts reference
///   them; archiving is the supported user-facing removal path.
/// - A card with recorded attempts can never change decks (v3 trigger):
///   immutable attempts name the deck that owned the card at recording
///   time, and re-parenting would strand that evidence.
public enum RecallDatabaseMigrator {
    public static let v1Identifier = "v1-initial-schema"
    public static let v2Identifier = "v2-query-indexes"
    public static let v3Identifier = "v3-evidence-deck-pinning"

    /// The append-only DELETE guards as one source of truth. The whole
    /// table reset ("delete all my data") runs inside a single IMMEDIATE
    /// transaction that drops these triggers, erases every row, and
    /// re-creates them before committing — so the protection is never
    /// permanently lost, and any rollback restores it.
    static let deleteTriggerStatements: [String] = [
        """
        CREATE TRIGGER attempt_no_delete
        BEFORE DELETE ON attempt
        BEGIN
            SELECT RAISE(ABORT, 'attempts are append-only evidence');
        END;
        """,
        """
        CREATE TRIGGER skip_no_delete
        BEFORE DELETE ON skip
        BEGIN
            SELECT RAISE(ABORT, 'skips are append-only evidence');
        END;
        """,
    ]

    static func installDeleteTriggers(_ db: Database) throws {
        for statement in deleteTriggerStatements {
            try db.execute(sql: statement)
        }
    }

    /// Migrations up to and including v1 (used by upgrade-fixture tests to
    /// build a "prior version" database before running the full migrator).
    public static var throughV1: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(v1Identifier) { db in
            try db.execute(sql: """
                CREATE TABLE deck (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    record TEXT NOT NULL
                );

                CREATE TABLE card (
                    id TEXT PRIMARY KEY NOT NULL,
                    deck_id TEXT NOT NULL REFERENCES deck(id) ON DELETE RESTRICT,
                    sort_order INTEGER NOT NULL,
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    record TEXT NOT NULL,
                    schedule TEXT
                );

                CREATE TABLE attempt (
                    id TEXT PRIMARY KEY NOT NULL,
                    card_id TEXT NOT NULL REFERENCES card(id) ON DELETE RESTRICT,
                    deck_id TEXT NOT NULL REFERENCES deck(id) ON DELETE RESTRICT,
                    timestamp REAL NOT NULL,
                    record TEXT NOT NULL,
                    schema_ok INTEGER NOT NULL DEFAULT 1
                        CHECK (schema_ok IN (0, 1))
                );

                CREATE TRIGGER attempt_no_update
                BEFORE UPDATE ON attempt
                BEGIN
                    SELECT RAISE(ABORT, 'attempts are append-only evidence');
                END;

                CREATE TABLE skip (
                    id TEXT PRIMARY KEY NOT NULL,
                    card_id TEXT NOT NULL REFERENCES card(id) ON DELETE RESTRICT,
                    session_id TEXT NOT NULL,
                    timestamp REAL NOT NULL
                );

                CREATE TRIGGER skip_no_update
                BEFORE UPDATE ON skip
                BEGIN
                    SELECT RAISE(ABORT, 'skips are append-only evidence');
                END;
                """)
            try Self.installDeleteTriggers(db)
            try db.execute(sql: """
                CREATE TABLE session (
                    id TEXT PRIMARY KEY NOT NULL,
                    deck_id TEXT NOT NULL REFERENCES deck(id) ON DELETE CASCADE,
                    status TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    record TEXT NOT NULL
                );
                """)
        }
        return migrator
    }

    /// The full migrator shipped by the app.
    public static var migrator: DatabaseMigrator {
        var migrator = throughV1
        migrator.registerMigration(v2Identifier) { db in
            try db.execute(sql: """
                CREATE INDEX idx_card_deck_sort ON card(deck_id, sort_order);
                CREATE INDEX idx_attempt_card_timestamp ON attempt(card_id, timestamp);
                CREATE INDEX idx_attempt_deck_timestamp ON attempt(deck_id, timestamp);
                CREATE INDEX idx_skip_card_timestamp ON skip(card_id, timestamp);
                CREATE INDEX idx_session_deck_status ON session(deck_id, status);
                """)
        }
        migrator.registerMigration(v3Identifier) { db in
            // Immutable attempts name the deck that owned their card at
            // recording time. Re-parenting an evidenced card to another
            // deck would leave durable evidence pointing at a deck that
            // no longer contains the card — a cross-deck join no honest
            // ledger reader wants. Enforce the pinning in the schema so
            // EVERY write path (save, import, restore, raw SQL) obeys it.
            try db.execute(sql: """
                CREATE TRIGGER card_no_reparent_with_evidence
                BEFORE UPDATE OF deck_id ON card
                WHEN OLD.deck_id != NEW.deck_id
                 AND EXISTS (SELECT 1 FROM attempt WHERE attempt.card_id = OLD.id)
                BEGIN
                    SELECT RAISE(ABORT, 're-parenting an evidenced card breaks attempt foreign key integrity');
                END;
                """)
        }
        return migrator
    }

    public static let identifiers = [v1Identifier, v2Identifier, v3Identifier]
}
