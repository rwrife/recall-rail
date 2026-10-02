import XCTest
import GRDB
@testable import RecallRailKit
@testable import RecallStore

/// Migration lifecycle: fresh install, idempotent re-migration, and an
/// upgrade fixture built on the v1-only schema then opened with the full
/// migrator.
final class MigrationTests: XCTestCase {

    private func applied(_ db: DatabaseQueue) throws -> Set<String> {
        try db.read { raw in
            try RecallDatabaseMigrator.migrator.appliedIdentifiers(raw)
        }
    }

    func testFreshInstallMigratesToHead() throws {
        let db = try RecallDatabase.openInMemory()
        XCTAssertEqual(try applied(db), Set(RecallDatabaseMigrator.identifiers))
        let report = try RecallRepository(db: db).integrityReport()
        XCTAssertEqual(report, ["ok", "ok"])
    }

    func testReOpeningExistingFileIsIdempotent() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rr-idempotent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try RecallDatabase.open(at: url)
        var repo = RecallRepository(db: first)
        let deck = StoreFixtures.deck()
        try repo.saveDeck(deck)

        // Reopen: the migrator must not re-run v1 (no "table already exists")
        // and data must survive untouched.
        let second = try RecallDatabase.open(at: url)
        XCTAssertEqual(try applied(second), Set(RecallDatabaseMigrator.identifiers))
        repo = RecallRepository(db: second)
        XCTAssertEqual(try repo.deck(id: deck.id)?.title, deck.title)

        // Third open for good measure — migration is a no-op every time.
        _ = try RecallDatabase.open(at: url)
    }

    func testUpgradeFromV1OnlyFixture() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rr-upgrade-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // Build a "prior release" database that only ever saw v1.
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let legacy = try DatabaseQueue(path: url.path, configuration: configuration)
        try RecallDatabaseMigrator.throughV1.migrate(legacy)
        let legacyApplied = try legacy.read { raw in
            try RecallDatabaseMigrator.throughV1.appliedIdentifiers(raw)
        }
        XCTAssertEqual(legacyApplied, Set([RecallDatabaseMigrator.v1Identifier]))

        // Seed data through the legacy schema.
        let repo = RecallRepository(db: legacy)
        let deck = StoreFixtures.deck(title: "Legacy deck")
        try repo.saveDeck(deck)
        let card = StoreFixtures.card(deckID: deck.id)
        try repo.saveCard(card)

        // Upgrade: reopening with the full migrator must add the later
        // migrations (v2 and v3) on top of the v1-only fixture.
        let upgraded = try RecallDatabase.open(at: url)
        XCTAssertEqual(try applied(upgraded), Set(RecallDatabaseMigrator.identifiers))
        let report = try RecallRepository(db: upgraded).integrityReport()
        XCTAssertEqual(report, ["ok", "ok"])
        XCTAssertEqual(try RecallRepository(db: upgraded).deck(id: deck.id)?.title, "Legacy deck")
        XCTAssertEqual(try RecallRepository(db: upgraded).cards(deckID: deck.id).count, 1)

        // v2 indexes exist.
        let indexNames = try upgraded.read { raw in
            try String.fetchAll(raw, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'")
        }
        XCTAssertEqual(Set(indexNames), [
            "idx_card_deck_sort", "idx_attempt_card_timestamp",
            "idx_attempt_deck_timestamp", "idx_skip_card_timestamp", "idx_session_deck_status",
        ])
    }

    func testForeignKeysAndNotNullChecksEnforced() throws {
        let db = try RecallDatabase.openInMemory()
        let repo = RecallRepository(db: db)

        // Card without its deck -> foreign key failure, mapped error.
        let orphan = StoreFixtures.card(deckID: StableID())
        XCTAssertThrowsError(try repo.saveCard(orphan)) { error in
            guard case StoreError.foreignKeyFailed = error else {
                return XCTFail("expected foreignKeyFailed, got \(error)")
            }
        }

        // CHECK constraint on is_archived flag.
        XCTAssertThrowsError(
            try db.rawExecute("INSERT INTO deck (id, title, is_archived, created_at, updated_at, record) VALUES ('x', 't', 7, 1, 1, '{}')")
        )
    }
}
