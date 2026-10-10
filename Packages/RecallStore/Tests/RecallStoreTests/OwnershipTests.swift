import XCTest
import Foundation
import GRDB
import RecallRailKit
@testable import RecallStore

final class OwnershipTests: XCTestCase {
    func fixture() throws -> RecallRepository {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let deck = StoreFixtures.deck(title: "Unicode 🛤, \"quotes\"\nline")
        try repo.saveDeck(deck)
        try repo.saveCard(StoreFixtures.card(deckID: deck.id))
        return repo
    }
    func testCompletePracticeRoundtripAndHistoryConflict() throws {
        let source = try fixture()
        let deck = try source.allDecks()[0]
        let card = try source.cards(deckID: deck.id)[0]
        var session = StudySession(deckID: deck.id, cardOrder: [card.id], mode: .tapReveal, startedAt: StoreFixtures.now, monotonicStartNanos: 0, monotonicCheckpointNanos: 0)
        try source.saveSession(session)
        let id = StableID()
        let before = ScheduleState.initial(at: StoreFixtures.now, algorithmVersion: 1)
        let after = try LeitnerScheduler().apply(grade: .recalled, to: before, at: StoreFixtures.now, attemptID: id)
        let attempt = Attempt(id: id, cardID: card.id, deckID: deck.id, timestamp: StoreFixtures.now, monotonicStartNanos: 0, monotonicEndNanos: 3_000_000, grade: .recalled, mode: .tapReveal, beforeSchedule: before, afterSchedule: after, algorithmVersion: 1)
        session = try source.recordAttempt(attempt, advancing: session)
        try source.recordSkip(cardID: card.id, sessionID: session.id, at: StoreFixtures.now)
        try source.setDeckArchived(id: deck.id, archived: true, at: StoreFixtures.now)
        try source.setCardArchived(id: card.id, archived: true, at: StoreFixtures.now)
        let bytes = try source.backupJSON()
        let target = RecallRepository(db: try RecallDatabase.openInMemory())
        try target.restore(target.previewRestore(bytes, mode: .replace))
        XCTAssertEqual(try target.backupJSON(), bytes)
        XCTAssertEqual(try target.attempts(cardID: card.id), [attempt])
        XCTAssertEqual(try target.session(id: session.id), session)
        var conflicting = try BackupCodec.decode(bytes)
        conflicting.tables["attempt"]![0].integers["schema_ok"] = 0
        XCTAssertThrowsError(try target.previewRestore(BackupCodec.encode(conflicting), mode: .merge))
        XCTAssertEqual(try target.backupJSON(), bytes)
        try target.eraseLocalRecords()
        let empty = try BackupCodec.decode(target.backupJSON())
        XCTAssertTrue(empty.tables.values.allSatisfy { $0.isEmpty })
        XCTAssertEqual(try target.db.rawInt("PRAGMA secure_delete"), 1)
    }
    func testHostileNestedSchemasAndBounds() throws {
        let original = try BackupCodec.decode(fixture().backupJSON())
        for table in ["deck", "card"] {
            var payload = original
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.tables[table]![0].strings["record"]!.utf8)) as? [String: Any])
            object["unknown"] = true
            payload.tables[table]![0].strings["record"] = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertThrowsError(try BackupCodec.encode(payload))
            object.removeValue(forKey: "unknown")
            object["id"] = ["rawValue": payload.tables[table]![0].strings["id"]!, "unknown": true]
            payload.tables[table]![0].strings["record"] = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertThrowsError(try BackupCodec.encode(payload))
        }
        for state in [ScheduleState(box: 1, dueAt: Date(timeIntervalSince1970: 1e13), algorithmVersion: 1), ScheduleState(box: 1, dueAt: StoreFixtures.now, consecutiveRecalls: Int.max, algorithmVersion: 1)] {
            var payload = original
            payload.tables["card"]![0].strings["schedule"] = try Snapshots.canonicalPayload(state)
            XCTAssertThrowsError(try BackupCodec.encode(payload))
        }
        var payload = original
        payload.tables["card"]![0].strings["schedule"] = "{\"box\":1,\"dueAt\":{\"referenceSeconds\":0,\"unknown\":1},\"consecutiveRecalls\":0,\"algorithmVersion\":1}"
        XCTAssertThrowsError(try BackupCodec.encode(payload))
    }
    func testLegacyAndUnknownClockRecordsBlockExportsWithoutMutation() throws {
        let repo = try fixture()
        let card = try repo.cards(deckID: repo.allDecks()[0].id)[0]
        let before = ScheduleState.initial(at: StoreFixtures.now, algorithmVersion: 1)
        let attempt = Attempt(cardID: card.id, deckID: card.deckID, timestamp: StoreFixtures.now, monotonicStartNanos: 100, monotonicEndNanos: 200, grade: .again, mode: .tapReveal, beforeSchedule: before, afterSchedule: before, algorithmVersion: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try Snapshots.canonicalPayload(attempt).utf8)) as? [String: Any])
        object.removeValue(forKey: "clockProvenance")
        let legacy = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        try repo.db.rawExecute("INSERT INTO attempt(id,card_id,deck_id,timestamp,record,schema_ok) VALUES (?,?,?,?,?,1)", [attempt.id.rawValue, card.id.rawValue, card.deckID.rawValue, StoreFixtures.now.timeIntervalSince1970, legacy])
        let snapshot = try repo.db.read { try BackupCodec.read($0) }
        XCTAssertThrowsError(try repo.backupJSON())
        XCTAssertThrowsError(try repo.attemptsCSV())
        XCTAssertEqual(try repo.db.read { try BackupCodec.read($0) }, snapshot)
        let target = RecallRepository(db: try RecallDatabase.openInMemory())
        let privateBytes = try BackupCodec.encode(snapshot)
        try target.restore(target.previewRestore(privateBytes, mode: .replace))
        XCTAssertEqual(try target.db.read { try BackupCodec.read($0) }, snapshot)
        XCTAssertThrowsError(try target.backupJSON())
    }
    func testSessionUnknownsAndNestedDateBounds() throws {
        let repo = try fixture()
        let card = try repo.cards(deckID: repo.allDecks()[0].id)[0]
        let session = StudySession(deckID: card.deckID, cardOrder: [card.id], mode: .tapReveal, startedAt: StoreFixtures.now, monotonicStartNanos: 0, monotonicCheckpointNanos: 0)
        try repo.saveSession(session)
        let original = try BackupCodec.decode(repo.backupJSON())
        for key in ["unknown", "startedAt", "clockProvenance"] {
            var payload = original
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.tables["session"]![0].strings["record"]!.utf8)) as? [String: Any])
            object[key] = key == "startedAt" ? "ref:" + String(Double(1e13).bitPattern, radix: 16) : "unknown"
            payload.tables["session"]![0].strings["record"] = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertThrowsError(try BackupCodec.encode(payload))
        }
    }
    func testUnknownAttemptFieldsRemainCorruptAfterPrivateRestore() throws {
        let repo = try fixture()
        let card = try repo.cards(deckID: repo.allDecks()[0].id)[0]
        let state = ScheduleState.initial(at: StoreFixtures.now, algorithmVersion: 1)
        let attempt = Attempt(cardID: card.id, deckID: card.deckID, timestamp: StoreFixtures.now, monotonicStartNanos: 0, monotonicEndNanos: 1_000_000, grade: .again, mode: .tapReveal, beforeSchedule: state, afterSchedule: state, algorithmVersion: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try Snapshots.canonicalPayload(attempt).utf8)) as? [String: Any])
        object["unknown"] = true
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        try repo.db.rawExecute("INSERT INTO attempt(id,card_id,deck_id,timestamp,record,schema_ok) VALUES (?,?,?,?,?,1)", [attempt.id.rawValue, card.id.rawValue, card.deckID.rawValue, StoreFixtures.now.timeIntervalSince1970, text])
        let bytes = try repo.db.read { try BackupCodec.encode(BackupCodec.read($0)) }
        let target = RecallRepository(db: try RecallDatabase.openInMemory())
        let preview = try target.previewRestore(bytes, mode: .replace)
        XCTAssertEqual(preview.corruptEvidenceCount, 1)
        try target.restore(preview)
        XCTAssertThrowsError(try target.attempts(cardID: card.id))
        XCTAssertThrowsError(try target.backupJSON())
        XCTAssertEqual(try target.db.read { try BackupCodec.encode(BackupCodec.read($0)) }, bytes)
    }
    func testSHA256KnownVector() {
        XCTAssertEqual(BackupCodec.checksum(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testRoundtripReplaceAndTriggers() throws {
        let source = try fixture()
        let data = try source.backupJSON()
        let target = try fixture()
        try target.restore(target.previewRestore(data, mode: .replace))
        XCTAssertEqual(try target.backupJSON(), data)
        XCTAssertEqual(try target.db.rawInt("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('attempt_no_delete','skip_no_delete','attempt_no_update','skip_no_update')"), 4)
    }
    func testPriorVersionAndRawCorruptEvidence() throws {
        let repo = try fixture()
        let card = try XCTUnwrap(repo.cards(deckID: repo.allDecks()[0].id).first)
        let id = UUID().uuidString
        try repo.db.rawExecute("INSERT INTO attempt(id,card_id,deck_id,timestamp,record,schema_ok) VALUES (?,?,?,?,?,0)", [id, card.id.rawValue, card.deckID.rawValue, 1.0, "broken { evidence"])
        let payload = try BackupCodec.decode(repo.db.read { try BackupCodec.encode(BackupCodec.read($0)) })
        let prior = try BackupCodec.encode(payload, version: 1)
        let target = RecallRepository(db: try RecallDatabase.openInMemory())
        try target.restore(target.previewRestore(prior, mode: .replace))
        XCTAssertEqual(try BackupCodec.decode(target.db.read { try BackupCodec.encode(BackupCodec.read($0)) }), payload)
        XCTAssertThrowsError(try target.db.rawExecute("DELETE FROM attempt"))
    }
    func testUnflaggedUndecodableEvidenceIsPreservedNotReclassified() throws {
        let source = try fixture()
        let card = try source.cards(deckID: source.allDecks()[0].id)[0]
        try source.db.rawExecute("INSERT INTO attempt(id,card_id,deck_id,timestamp,record,schema_ok) VALUES (?,?,?,?,?,1)", [UUID().uuidString, card.id.rawValue, card.deckID.rawValue, 1.0, "not JSON"])
        let bytes = try source.db.read { try BackupCodec.encode(BackupCodec.read($0)) }
        let target = RecallRepository(db: try RecallDatabase.openInMemory())
        let preview = try target.previewRestore(bytes, mode: .replace)
        XCTAssertEqual(preview.corruptEvidenceCount, 1)
        try target.restore(preview)
        XCTAssertEqual(try target.db.read { try BackupCodec.encode(BackupCodec.read($0)) }, bytes)
        XCTAssertThrowsError(try target.attempts(cardID: card.id))
        XCTAssertEqual(try target.db.rawInt("SELECT schema_ok FROM attempt"), 1)
    }
    func testPriorVersionNumericDates() throws {
        let source = try fixture()
        var payload = try BackupCodec.decode(source.backupJSON())
        for table in ["deck", "card"] {
            for index in payload.tables[table]!.indices {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.tables[table]![index].strings["record"]!.utf8)) as? [String: Any])
                object["createdAt"] = StoreFixtures.now.timeIntervalSince1970
                object["updatedAt"] = StoreFixtures.now.timeIntervalSince1970
                payload.tables[table]![index].strings["record"] = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            }
        }
        let target = RecallRepository(db: try RecallDatabase.openInMemory())
        try target.restore(target.previewRestore(BackupCodec.encode(payload, version: 1), mode: .replace))
        XCTAssertEqual(try target.allDecks(), try source.allDecks())
        XCTAssertEqual(try BackupCodec.decode(target.backupJSON()), payload)
    }
    func testCorruptionDuplicateIDsReferencesAndBounds() throws {
        let repo = try fixture()
        let bytes = try repo.backupJSON()
        var envelope = try JSONDecoder().decode(BackupEnvelope.self, from: bytes)
        envelope.payload.append(0)
        XCTAssertThrowsError(try BackupCodec.decode(JSONEncoder().encode(envelope)))
        var payload = try BackupCodec.decode(bytes)
        payload.tables["deck"]!.append(payload.tables["deck"]![0])
        XCTAssertThrowsError(try BackupCodec.encode(payload))
        payload = try BackupCodec.decode(bytes)
        payload.tables["card"]![0].strings["deck_id"] = UUID().uuidString
        XCTAssertThrowsError(try BackupCodec.encode(payload))
        XCTAssertThrowsError(try BackupCodec.decode(Data(repeating: 0, count: BackupCodec.maximumBytes + 1)))
    }
    func testStrictUnknownFieldsAndInvalidSchedule() throws {
        let source = try fixture()
        let bytes = try source.backupJSON()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        envelope["unexpected"] = true
        XCTAssertThrowsError(try BackupCodec.decode(JSONSerialization.data(withJSONObject: envelope)))
        var payload = try BackupCodec.decode(bytes)
        let state = ScheduleState(box: 99, dueAt: StoreFixtures.now, consecutiveRecalls: -1, algorithmVersion: 1)
        payload.tables["card"]![0].strings["schedule"] = try Snapshots.canonicalPayload(state)
        XCTAssertThrowsError(try BackupCodec.encode(payload))
        payload = try BackupCodec.decode(bytes)
        var duplicate = payload.tables["deck"]![0]
        duplicate.strings["id"] = duplicate.strings["id"]!.lowercased()
        payload.tables["deck"]!.append(duplicate)
        XCTAssertThrowsError(try BackupCodec.encode(payload))
    }
    func testScheduleReferenceMustAgreeWithLastAttemptSnapshot() throws {
        let source = try fixture()
        let card = try source.cards(deckID: source.allDecks()[0].id)[0]
        let id = StableID()
        let before = ScheduleState.initial(at: StoreFixtures.now, algorithmVersion: 1)
        let after = try LeitnerScheduler().apply(grade: .recalled, to: before, at: StoreFixtures.now, attemptID: id)
        let attempt = Attempt(id: id, cardID: card.id, deckID: card.deckID, timestamp: StoreFixtures.now, monotonicStartNanos: 0, monotonicEndNanos: 1_000_000, grade: .recalled, mode: .tapReveal, beforeSchedule: before, afterSchedule: after, algorithmVersion: 1)
        try source.recordAttempt(attempt)
        var payload = try BackupCodec.decode(source.backupJSON())
        var inconsistent = after; inconsistent.box = 1
        payload.tables["card"]![0].strings["schedule"] = try Snapshots.canonicalPayload(inconsistent)
        XCTAssertThrowsError(try BackupCodec.encode(payload))
        inconsistent = after; inconsistent.lastAttemptID = StableID()
        payload.tables["card"]![0].strings["schedule"] = try Snapshots.canonicalPayload(inconsistent)
        XCTAssertThrowsError(try BackupCodec.encode(payload))
    }
    func testStalePreviewAndMergeConflictLeaveDatabaseUnchanged() throws {
        let repo = try fixture()
        let bytes = try repo.backupJSON()
        let preview = try repo.previewRestore(bytes, mode: .replace)
        try repo.saveDeck(StoreFixtures.deck(title: "New local deck"))
        let changed = try repo.backupJSON()
        XCTAssertThrowsError(try repo.restore(preview))
        XCTAssertEqual(try repo.backupJSON(), changed)
        var deck = try repo.allDecks()[0]; deck.title = "changed"
        try repo.saveDeck(deck)
        XCTAssertThrowsError(try repo.previewRestore(bytes, mode: .merge))
    }
    func testNoOpWriteStillInvalidatesPreview() throws {
        let repo = try fixture()
        let bytes = try repo.backupJSON()
        let preview = try repo.previewRestore(bytes, mode: .replace)
        try repo.db.rawExecute("UPDATE deck SET title = title")
        XCTAssertEqual(try repo.backupJSON(), bytes)
        XCTAssertThrowsError(try repo.restore(preview)) { error in
            XCTAssertEqual(error as? OwnershipError, .stalePreview)
        }
    }
    func testMergeAddsAndSkipsExactRecords() throws {
        let source = try fixture()
        let target = RecallRepository(db: try RecallDatabase.openInMemory())
        let bytes = try source.backupJSON()
        try target.restore(target.previewRestore(bytes, mode: .merge))
        try target.restore(target.previewRestore(bytes, mode: .merge))
        XCTAssertEqual(try target.backupJSON(), bytes)
    }
    func testRollbackRestoresRowsAndTriggersOnMidRestoreSQLFailure() throws {
        let source = try fixture(); let target = try fixture()
        let original = try target.backupJSON()
        let preview = try target.previewRestore(source.backupJSON(), mode: .replace)
        try target.db.rawExecute("CREATE TRIGGER injected_failure BEFORE INSERT ON card BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        XCTAssertThrowsError(try target.restore(preview))
        XCTAssertEqual(try target.backupJSON(), original)
        XCTAssertEqual(try target.db.rawInt("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('attempt_no_delete','skip_no_delete')"), 2)
    }
    func testLargeFixtureAndCSV() throws {
        let repo = try fixture()
        let deck = try repo.allDecks()[0]
        let cards = (0..<5_000).map { StoreFixtures.card(deckID: deck.id, prompt: "Prompt \($0), 🛤", sortOrder: $0 + 1) }
        _ = try repo.importCards(cards, mode: .allOrNothing)
        let bytes = try repo.backupJSON()
        let target = RecallRepository(db: try RecallDatabase.openInMemory())
        try target.restore(target.previewRestore(bytes, mode: .replace))
        XCTAssertEqual(try target.cards(deckID: deck.id).count, 5_001)
        XCTAssertEqual(try target.backupJSON(), bytes)
        XCTAssertTrue(try repo.decksCSV().contains("\"\"quotes\"\""))
        XCTAssertTrue(try repo.attemptsCSV().contains("raw_record"))
    }
}
