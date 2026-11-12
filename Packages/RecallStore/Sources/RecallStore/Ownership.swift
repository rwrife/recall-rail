import Foundation
import GRDB
import RecallRailKit
#if canImport(CryptoKit)
import CryptoKit
#else
import LinuxSHA
#endif

public enum OwnershipError: Error, Equatable {
    case invalid(String)
    case stalePreview
    case conflict(String)
}

/// Raw columns are authoritative: unreadable evidence remains unreadable after restore.
public struct BackupRow: Codable, Equatable, Sendable {
    public var strings: [String: String]
    public var integers: [String: Int64]
    public var reals: [String: Double]
}
public struct BackupPayload: Codable, Equatable, Sendable {
    public var tables: [String: [BackupRow]]
}
public struct BackupEnvelope: Codable, Sendable {
    public var version: Int
    public var payload: Data
    public var sha256: String
}
public enum RestoreMode: String, CaseIterable, Sendable { case replace, merge }
public struct RestorePreview: Sendable {
    public let mode: RestoreMode
    public let counts: [String: Int]
    public let existingCounts: [String: Int]
    public let corruptEvidenceCount: Int
    fileprivate let payload: BackupPayload
    fileprivate let baseline: String
    fileprivate let changeCount: Int64
    fileprivate let dataVersion: Int64
}

public enum BackupCodec {
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumRows = 100_000
    static let tables = ["deck", "card", "attempt", "session", "skip"]
    static let columns: [String: ([String], [String], [String])] = [
        "deck": (["id", "title", "record"], ["is_archived"], ["created_at", "updated_at"]),
        "card": (["id", "deck_id", "record", "schedule"], ["sort_order", "is_archived"], ["created_at", "updated_at"]),
        "attempt": (["id", "card_id", "deck_id", "record"], ["schema_ok"], ["timestamp"]),
        "session": (["id", "deck_id", "status", "record"], [], ["updated_at"]),
        "skip": (["id", "card_id", "session_id"], [], ["timestamp"])
    ]
    public static func checksum(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            recall_sha256(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
        #endif
    }
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func encode(_ payload: BackupPayload, version: Int = 2) throws -> Data {
        guard [1, 2].contains(version) else { throw OwnershipError.invalid("Unsupported backup version") }
        try validate(payload)
        let bytes = try canonical(payload)
        let envelope = BackupEnvelope(version: version, payload: bytes, sha256: checksum(bytes))
        let data = try canonical(envelope)
        guard data.count <= maximumBytes else { throw OwnershipError.invalid("Backup too large") }
        return data
    }
    public static func decode(_ data: Data) throws -> BackupPayload {
        guard data.count <= maximumBytes else { throw OwnershipError.invalid("Backup too large") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == Set(["version", "payload", "sha256"]) else { throw OwnershipError.invalid("Invalid envelope fields") }
        let envelope = try JSONDecoder().decode(BackupEnvelope.self, from: data)
        guard [1, 2].contains(envelope.version), checksum(envelope.payload) == envelope.sha256 else {
            throw OwnershipError.invalid("Unsupported version or checksum mismatch")
        }
        // v1 uses the same raw-column envelope; domain dates may be epoch numbers.
        guard let object = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any], Set(object.keys) == Set(["tables"]), let tablesObject = object["tables"] as? [String: Any] else { throw OwnershipError.invalid("Invalid payload fields") }
        for rows in tablesObject.values {
            guard let rows = rows as? [[String: Any]], rows.allSatisfy({ Set($0.keys) == Set(["strings", "integers", "reals"]) }) else { throw OwnershipError.invalid("Invalid row fields") }
        }
        let payload = try JSONDecoder().decode(BackupPayload.self, from: envelope.payload)
        try validate(payload)
        return payload
    }
    static func validate(_ payload: BackupPayload) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            guard condition else { throw OwnershipError.invalid(reason) }
        }
        try require(Set(payload.tables.keys) == Set(tables), "Incomplete or unknown tables")
        try require(payload.tables.values.reduce(0) { $0 + $1.count } <= maximumRows, "Too many records")
        var indexed: [String: [String: BackupRow]] = [:]
        for table in tables {
            let spec = columns[table]!
            var rows: [String: BackupRow] = [:]
            var normalizedIDs = Set<UUID>()
            for row in payload.tables[table]! {
                let id = row.strings["id"] ?? ""
                try require(UUID(uuidString: id) != nil && rows[id] == nil && normalizedIDs.insert(UUID(uuidString: id)!).inserted, "Invalid or duplicate ID in \(table)")
                let requiredStrings = Set(spec.0.filter { $0 != "schedule" })
                try require(Set(row.strings.keys).isSubset(of: Set(spec.0)) && requiredStrings.isSubset(of: Set(row.strings.keys)) && Set(row.integers.keys) == Set(spec.1) && Set(row.reals.keys) == Set(spec.2), "Invalid columns")
                try require(row.reals.values.allSatisfy { $0.isFinite && abs($0) <= 1_000_000_000_000 } && row.strings.values.allSatisfy { $0.utf8.count <= 1_048_576 }, "Invalid value or oversized field")
                for key in ["is_archived", "schema_ok"] where row.integers[key] != nil {
                    try require([0, 1].contains(row.integers[key]!), "Invalid boolean")
                }
                rows[id] = row
            }
            indexed[table] = rows
        }
        func decode<T: Decodable>(_ row: BackupRow, _ type: T.Type, column: String = "record") throws -> T {
            let kind = column == "schedule" ? "schedule" : (type == Deck.self ? "deck" : type == Card.self ? "card" : "session")
            try OwnershipSchema.validate(row.strings[column]!, kind: kind)
            return try JSONDecoder.domain.decode(type, from: Data(row.strings[column]!.utf8))
        }
        func scheduleValid(_ value: ScheduleState) -> Bool {
            OwnershipSchema.scheduleValid(value)
        }
        func tagsValid(_ tags: [String]) -> Bool {
            tags.count <= 1_000 && tags.allSatisfy { !$0.isEmpty && $0.utf8.count <= 1_024 }
        }
        func datesMatch(_ created: Date, _ updated: Date, _ row: BackupRow) -> Bool {
            created.timeIntervalSince1970 == row.reals["created_at"] && updated.timeIntervalSince1970 == row.reals["updated_at"]
        }
        for (id, row) in indexed["deck"]! {
            let value = try decode(row, Deck.self)
            try require(value.id.rawValue == id && value.title == row.strings["title"], "Deck identity mismatch")
            try require(!value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tagsValid(value.tags), "Invalid deck fields")
            try require(value.isArchived == (row.integers["is_archived"] == 1) && datesMatch(value.createdAt, value.updatedAt, row), "Deck snapshot mismatch")
        }
        for (id, row) in indexed["card"]! {
            let value = try decode(row, Card.self)
            try require(value.id.rawValue == id && value.deckID.rawValue == row.strings["deck_id"], "Card identity mismatch")
            try require(indexed["deck"]![value.deckID.rawValue] != nil, "Missing card deck")
            try require(!value.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tagsValid(value.tags), "Invalid card fields")
            try require(Int64(value.sortOrder) == row.integers["sort_order"] && value.isArchived == (row.integers["is_archived"] == 1), "Card snapshot mismatch")
            try require(datesMatch(value.createdAt, value.updatedAt, row), "Card dates mismatch")
            if row.strings["schedule"] != nil {
                let state = try decode(row, ScheduleState.self, column: "schedule")
                try require(scheduleValid(state), "Invalid schedule")
                if let last = state.lastAttemptID {
                    guard let attemptRow = indexed["attempt"]![last.rawValue] else { throw OwnershipError.invalid("Missing last attempt") }
                    try require(attemptRow.strings["card_id"] == id, "Schedule reference mismatch")
                    // Corrupt evidence is preserved, never promoted to readable history.
                    if let attempt = readableAttempt(attemptRow) {
                        try require(attempt.afterSchedule == state, "Schedule does not match last attempt")
                    }
                }
            }
        }
        for (id, row) in indexed["attempt"]! {
            guard let card = indexed["card"]![row.strings["card_id"]!] else { throw OwnershipError.invalid("Missing attempt card") }
            try require(card.strings["deck_id"] == row.strings["deck_id"], "Attempt deck mismatch")
            if let value = readableAttempt(row) {
                try require(value.id.rawValue == id && value.timestamp.timeIntervalSince1970 == row.reals["timestamp"], "Readable attempt snapshot mismatch")
            }
            // Everything else remains raw corrupt evidence with its original schema_ok.

        }
        for (id, row) in indexed["session"]! {
            let value = try decode(row, StudySession.self)
            try require(value.id.rawValue == id && value.deckID.rawValue == row.strings["deck_id"] && indexed["deck"]![value.deckID.rawValue] != nil, "Session identity mismatch")
            try require(value.status.rawValue == row.strings["status"] && (value.endedAt ?? value.startedAt).timeIntervalSince1970 == row.reals["updated_at"], "Session snapshot mismatch")
            try require(value.cursor >= 0 && value.cursor <= value.cardOrder.count && Set(value.cardOrder).count == value.cardOrder.count, "Invalid session cursor or order")
            try require(value.status != .completed || value.cursor == value.cardOrder.count, "Incomplete completed session")
            try require((value.status != .active && value.status != .interrupted) || value.cursor < value.cardOrder.count, "Active session has no current card")
            for card in value.cardOrder { try require(indexed["card"]![card.rawValue]?.strings["deck_id"] == value.deckID.rawValue, "Session card mismatch") }
        }
        for row in indexed["skip"]!.values {
            try require(indexed["card"]![row.strings["card_id"]!] != nil && indexed["session"]![row.strings["session_id"]!]?.strings["deck_id"] == indexed["card"]![row.strings["card_id"]!]?.strings["deck_id"], "Skip reference mismatch")
        }
    }
    static func readableAttempt(_ row: BackupRow) -> Attempt? {
        guard row.integers["schema_ok"] == 1,
              let text = row.strings["record"],
              (try? OwnershipSchema.validate(text, kind: "attempt")) != nil,
              let value = try? JSONDecoder.domain.decode(Attempt.self, from: Data(text.utf8)),
              OwnershipSchema.scheduleValid(value.beforeSchedule), OwnershipSchema.scheduleValid(value.afterSchedule),
              value.monotonicEndNanos >= value.monotonicStartNanos,
              UInt64(value.elapsedMilliseconds) == (value.monotonicEndNanos - value.monotonicStartNanos) / 1_000_000,
              value.id.rawValue == row.strings["id"],
              value.timestamp.timeIntervalSince1970 == row.reals["timestamp"],
              value.cardID.rawValue == row.strings["card_id"], value.deckID.rawValue == row.strings["deck_id"],
              value.elapsedMilliseconds >= 0,
              (1...SchedulingRules.maxBox).contains(value.beforeSchedule.box),
              (1...SchedulingRules.maxBox).contains(value.afterSchedule.box),
              value.beforeSchedule.consecutiveRecalls >= 0, value.afterSchedule.consecutiveRecalls >= 0,
              value.beforeSchedule.algorithmVersion == value.algorithmVersion,
              value.afterSchedule.algorithmVersion == value.algorithmVersion,
              !SchedulingRules.rows(version: value.algorithmVersion).isEmpty else { return nil }
        return value
    }
    /// Export gates never normalize or rewrite immutable evidence. Unknown bytes
    /// cannot be proven free of boot anchors, so complete export fails atomically.
    static func requireExportableClocks(_ payload: BackupPayload) throws {
        for table in ["attempt", "session"] {
            for row in payload.tables[table] ?? [] {
                guard let text = row.strings["record"],
                      (try? OwnershipSchema.validate(text, kind: table)) != nil,
                      (table == "attempt" ? (try? JSONDecoder.domain.decode(Attempt.self, from: Data(text.utf8))) != nil : (try? JSONDecoder.domain.decode(StudySession.self, from: Data(text.utf8))) != nil),
                      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      object["clockProvenance"] as? String == ClockProvenance.appOriginElapsedV1.rawValue else {
                    throw OwnershipError.invalid("Export blocked: legacy or unreadable clock evidence must remain on this device. Local history is unchanged. Complete-history backup needs an approved lossless privacy policy; do not delete history to bypass this gate.")
                }
            }
        }
    }
    static func read(_ db: Database) throws -> BackupPayload {
        var result: [String: [BackupRow]] = [:]
        for table in tables {
            let spec = columns[table]!
            result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY id").map { row in
                var strings: [String: String] = [:]; var integers: [String: Int64] = [:]; var reals: [String: Double] = [:]
                for key in spec.0 { let value: String? = row[key]; strings[key] = value }
                for key in spec.1 { integers[key] = row[key] }
                for key in spec.2 { reals[key] = row[key] }
                return BackupRow(strings: strings, integers: integers, reals: reals)
            }
        }
        return BackupPayload(tables: result)
    }
    static func fingerprint(_ payload: BackupPayload) throws -> String { checksum(try canonical(payload)) }
    static func combined(_ incoming: BackupPayload, _ current: BackupPayload) throws -> BackupPayload {
        var result = current
        for table in tables {
            let existing = Dictionary(uniqueKeysWithValues: current.tables[table]!.map { ($0.strings["id"]!, $0) })
            for row in incoming.tables[table]! {
                if let previous = existing[row.strings["id"]!] {
                    guard previous == row else { throw OwnershipError.conflict("\(table) ID already has different data") }
                } else { result.tables[table]!.append(row) }
            }
        }
        try validate(result)
        return result
    }
}

extension RecallRepository {
    public func backupJSON() throws -> Data {
        try db.read { raw in
            let payload = try BackupCodec.read(raw)
            try BackupCodec.requireExportableClocks(payload)
            return try BackupCodec.encode(payload)
        }
    }
    public func previewRestore(_ data: Data, mode: RestoreMode) throws -> RestorePreview {
        let payload = try BackupCodec.decode(data)
        return try db.read { raw in
            let current = try BackupCodec.read(raw)
            if mode == .merge { _ = try BackupCodec.combined(payload, current) }
            return RestorePreview(mode: mode, counts: payload.tables.mapValues(\.count), existingCounts: current.tables.mapValues(\.count), corruptEvidenceCount: payload.tables["attempt"]!.filter { BackupCodec.readableAttempt($0) == nil }.count, payload: payload, baseline: try BackupCodec.fingerprint(current), changeCount: try Int64.fetchOne(raw, sql: "SELECT total_changes()")!, dataVersion: try Int64.fetchOne(raw, sql: "PRAGMA data_version")!)
        }
    }
    public func restore(_ preview: RestorePreview) throws {
        try db.write { raw in
            let current = try BackupCodec.read(raw)
            let changes = try Int64.fetchOne(raw, sql: "SELECT total_changes()")!
            let version = try Int64.fetchOne(raw, sql: "PRAGMA data_version")!
            guard changes == preview.changeCount, version == preview.dataVersion,
                  try BackupCodec.fingerprint(current) == preview.baseline else { throw OwnershipError.stalePreview }
            try BackupCodec.validate(preview.payload)
            if preview.mode == .merge { _ = try BackupCodec.combined(preview.payload, current) }
            if preview.mode == .replace {
                try raw.execute(sql: "DROP TRIGGER attempt_no_delete; DROP TRIGGER skip_no_delete;")
                try raw.execute(sql: "DELETE FROM skip; DELETE FROM attempt; DELETE FROM session; DELETE FROM card; DELETE FROM deck;")
            }
            for table in BackupCodec.tables {
                let existing = Set(current.tables[table]!.map { $0.strings["id"]! })
                for row in preview.payload.tables[table]! {
                    if preview.mode == .merge && existing.contains(row.strings["id"]!) { continue }
                    let spec = BackupCodec.columns[table]!
                    let keys = spec.0 + spec.1 + spec.2
                    let values: [DatabaseValueConvertible?] = spec.0.map { row.strings[$0] as (any DatabaseValueConvertible)? } + spec.1.map { row.integers[$0] as (any DatabaseValueConvertible)? } + spec.2.map { row.reals[$0] as (any DatabaseValueConvertible)? }
                    try raw.execute(sql: "INSERT INTO \(table) (\(keys.joined(separator: ","))) VALUES (\(keys.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(values))
                }
            }
            if preview.mode == .replace { try RecallDatabaseMigrator.installDeleteTriggers(raw) }
        }
    }
    public func attemptsCSV() throws -> String {
        try db.read { raw in
            let payload = try BackupCodec.read(raw)
            try BackupCodec.requireExportableClocks(BackupPayload(tables: ["attempt": payload.tables["attempt"] ?? []]))
            let rows = try Row.fetchAll(raw, sql: "SELECT id,card_id,deck_id,timestamp,schema_ok,record FROM attempt ORDER BY timestamp,id")
            var output = [["id", "card_id", "deck_id", "timestamp", "schema_ok", "evidence_status", "grade", "mode", "elapsed_ms", "before_box", "before_due", "after_box", "after_due", "algorithm_version", "raw_record"]]
            for row in rows {
                let id: String = row["id"]; let card: String = row["card_id"]; let deck: String = row["deck_id"]
                let timestamp: Double = row["timestamp"]; let ok: Int = row["schema_ok"]; let record: String = row["record"]
                let rawRow = BackupRow(strings: ["id": id, "card_id": card, "deck_id": deck, "record": record], integers: ["schema_ok": Int64(ok)], reals: ["timestamp": timestamp])
                if let attempt = BackupCodec.readableAttempt(rawRow) {
                    let details = [attempt.grade.rawValue, attempt.mode.rawValue, String(attempt.elapsedMilliseconds), String(attempt.beforeSchedule.box), String(attempt.beforeSchedule.dueAt.timeIntervalSince1970), String(attempt.afterSchedule.box), String(attempt.afterSchedule.dueAt.timeIntervalSince1970), String(attempt.algorithmVersion)]
                    output.append([id, card, deck, String(timestamp), String(ok), "readable"] + details + [record])
                } else {
                    output.append([id, card, deck, String(timestamp), String(ok), "corrupt"] + Array(repeating: "", count: 8) + [record])
                }
            }
            return CSVDocument.serialize(rows: output)
        }
    }
    public func decksCSV() throws -> String {
        let decks = try allDecks(includeArchived: true)
        let rows = [["id", "title", "notes", "tags", "archived", "created_at", "updated_at"]] + decks.map { [$0.id.rawValue, $0.title, $0.notes, $0.tags.joined(separator: ";"), String($0.isArchived), String($0.createdAt.timeIntervalSince1970), String($0.updatedAt.timeIntervalSince1970)] }
        return CSVDocument.serialize(rows: rows)
    }
    static func csvField(_ text: String) -> String { CSVDocument.escapeField(text) }
}
