import Foundation
import GRDB
import RecallRailKit

/// Transactional repository over the app-owned SQLite database.
///
/// Every mutation goes through GRDB writes; multi-step operations run in a
/// single transaction so a mid-way failure rolls the whole operation back.
/// Attempt and skip rows are protected by append-only triggers — the
/// repository never issues UPDATE/DELETE against them, and the database
/// rejects any other writer that tries.
public struct RecallRepository: Sendable {
    public let db: DatabaseQueue

    public init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Decks

    /// Save a deck's editable fields. `createdAt` is PRESERVED (COALESCE)
    /// the same way `saveCard` preserves `schedule`: an in-place deck edit
    /// updates content and `updatedAt` but can never rewind the creation
    /// instant, which is ordering metadata decks are listed by.
    public func saveDeck(_ deck: Deck, preserveCreatedAt: Bool = false) throws {
        let snapshot = Snapshots.DeckSnapshot(deck: deck)
        let record = try Snapshots.canonicalPayload(deck)
        guard preserveCreatedAt else {
            try mutate(sql: """
                INSERT INTO deck (id, title, is_archived, created_at, updated_at, record)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    is_archived = excluded.is_archived,
                    updated_at = excluded.updated_at,
                    record = excluded.record;
                """,
                values: [snapshot.id, snapshot.title, snapshot.isArchived ? 1 : 0,
                         snapshot.createdAt.timeIntervalSince1970,
                         snapshot.updatedAt.timeIntervalSince1970,
                         record],
                table: "deck", id: snapshot.id)
            return
        }
        try mutate(sql: """
            INSERT INTO deck (id, title, is_archived, created_at, updated_at, record)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                is_archived = excluded.is_archived,
                updated_at = excluded.updated_at,
                record = excluded.record,
                created_at = COALESCE(deck.created_at, excluded.created_at);
            """,
            values: [snapshot.id, snapshot.title, snapshot.isArchived ? 1 : 0,
                     snapshot.createdAt.timeIntervalSince1970,
                     snapshot.updatedAt.timeIntervalSince1970,
                     record],
            table: "deck", id: snapshot.id)
    }

    public func deck(id: StableID) throws -> Deck? {
        try db.read { raw in
            guard let row = try Row.fetchOne(raw, sql: "SELECT record FROM deck WHERE id = ?", arguments: [id.rawValue]) else {
                return nil
            }
            return try row.domainValue("record")
        }
    }

    public func allDecks(includeArchived: Bool = false) throws -> [Deck] {
        let sql = """
            SELECT record FROM deck
            \(includeArchived ? "" : "WHERE is_archived = 0")
            ORDER BY created_at ASC;
            """
        return try db.read { raw in
            try Row.fetchAll(raw, sql: sql).map { (row: Row) throws in
                try row.domainValue("record") as Deck
            }
        }
    }

    public func setDeckArchived(id: StableID, archived: Bool, at instant: Date) throws {
        try db.write { raw in
            try raw.inSavepoint {
                guard let row = try Row.fetchOne(raw, sql: "SELECT record FROM deck WHERE id = ?", arguments: [id.rawValue]) else {
                    return .rollback
                }
                var deck: Deck = try row.domainValue("record")
                deck.isArchived = archived
                deck.updatedAt = instant
                try raw.execute(
                    sql: """
                    UPDATE deck SET title = ?, is_archived = ?, updated_at = ?, record = ?
                    WHERE id = ?;
                    """,
                    arguments: [deck.title, archived ? 1 : 0,
                                instant.timeIntervalSince1970,
                                try Snapshots.canonicalPayload(deck), id.rawValue]
                )
                return .commit
            }
        }
    }

    /// Hard-delete a deck and its cards. Fails with
    /// `StoreError.foreignKeyFailed` while any attempt still references the
    /// deck or its cards — history outlives the objects it describes, so a
    /// deck carrying evidence can only be archived, never erased.
    /// Also rejects deletion while any active or interrupted session still
    /// references the deck or its queued cards.
    public func deleteDeck(id: StableID) throws {
        try db.write { raw in
            try raw.inSavepoint {
                let activeSessions = try String.fetchAll(raw, sql: """
                    SELECT id FROM session
                    WHERE deck_id = ? AND status IN ('active', 'interrupted');
                    """, arguments: [id.rawValue])
                guard activeSessions.isEmpty else {
                    throw StoreError.rolledBack(reason: "deck has active or interrupted practice session")
                }
                try raw.execute(
                    sql: "DELETE FROM card WHERE deck_id = ? AND id NOT IN (SELECT card_id FROM attempt)",
                    arguments: [id.rawValue]
                )
                do {
                    try raw.execute(sql: "DELETE FROM deck WHERE id = ?", arguments: [id.rawValue])
                } catch {
                    throw RecallDatabase.mapSQLError(error, table: "deck", id: id.rawValue)
                }
                return .commit
            }
        }
    }

    // MARK: - Cards & schedules

    /// Save a card's editable fields. `schedule` is the current schedule
    /// snapshot; when `nil` the stored schedule is PRESERVED (COALESCE), so
    /// a routine card edit can never wipe scheduling progress. The
    /// scheduler owns schedule changes through `setSchedule`/`recordAttempt`.
    public func saveCard(_ card: Card, schedule: ScheduleState? = nil) throws {
        let snapshot = try Snapshots.CardSnapshot(card: card, schedule: schedule)
        try mutate(sql: """
            INSERT INTO card (id, deck_id, sort_order, is_archived, created_at, updated_at, record, schedule)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                deck_id = excluded.deck_id,
                sort_order = excluded.sort_order,
                is_archived = excluded.is_archived,
                updated_at = excluded.updated_at,
                record = excluded.record,
                schedule = COALESCE(excluded.schedule, card.schedule);
            """,
            values: [snapshot.id, snapshot.deckID, snapshot.sortOrder,
                     snapshot.isArchived ? 1 : 0,
                     snapshot.createdAt.timeIntervalSince1970,
                     snapshot.updatedAt.timeIntervalSince1970,
                     snapshot.record, snapshot.schedule],
            table: "card", id: snapshot.id)
    }

    public func card(id: StableID) throws -> Card? {
        try db.read { raw in
            guard let row = try Row.fetchOne(raw, sql: "SELECT record FROM card WHERE id = ?", arguments: [id.rawValue]) else {
                return nil
            }
            return try row.domainValue("record")
        }
    }

    public func cards(deckID: StableID, includeArchived: Bool = false) throws -> [Card] {
        let sql = """
            SELECT record FROM card
            WHERE deck_id = ?
            \(includeArchived ? "" : "AND is_archived = 0")
            ORDER BY sort_order ASC;
            """
        return try db.read { raw in
            try Row.fetchAll(raw, sql: sql, arguments: [deckID.rawValue]).map { (row: Row) throws in
                try row.domainValue("record") as Card
            }
        }
    }

    /// Reorder every active card in a deck in one transaction. A stale or
    /// filtered list is rejected rather than silently reordering a subset.
    public func reorderCards(deckID: StableID, orderedIDs: [StableID], at instant: Date) throws {
        try db.write { raw in
            try raw.inSavepoint {
                let stored = try Row.fetchAll(raw, sql: """
                    SELECT record FROM card WHERE deck_id = ? AND is_archived = 0
                    ORDER BY sort_order, id
                    """, arguments: [deckID.rawValue])
                    .map { (row: Row) throws -> Card in try row.domainValue("record") }
                guard orderedIDs.count == stored.count,
                      Set(orderedIDs) == Set(stored.map(\.id)) else {
                    throw StoreError.rolledBack(reason: "reorder requires every active card in this deck")
                }
                let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
                for (index, id) in orderedIDs.enumerated() {
                    var card = byID[id]!
                    card.sortOrder = index
                    card.updatedAt = instant
                    try raw.execute(sql: "UPDATE card SET sort_order = ?, updated_at = ?, record = ? WHERE id = ?",
                                    arguments: [index, instant.timeIntervalSince1970,
                                                try Snapshots.canonicalPayload(card), id.rawValue])
                }
                return .commit
            }
        }
    }

    public func setCardArchived(id: StableID, archived: Bool, at instant: Date) throws {
        try db.write { raw in
            try raw.inSavepoint {
                guard let row = try Row.fetchOne(
                    raw, sql: "SELECT record, schedule FROM card WHERE id = ?", arguments: [id.rawValue]
                ) else {
                    return .rollback
                }
                var card: Card = try row.domainValue("record")
                card.isArchived = archived
                card.updatedAt = instant
                let scheduleText: String? = row["schedule"]
                try raw.execute(
                    sql: """
                    UPDATE card SET is_archived = ?, updated_at = ?, record = ?, schedule = ?
                    WHERE id = ?;
                    """,
                    arguments: [archived ? 1 : 0, instant.timeIntervalSince1970,
                                try Snapshots.canonicalPayload(card), scheduleText, id.rawValue]
                )
                return .commit
            }
        }
    }

    public func schedule(cardID: StableID) throws -> ScheduleState? {
        try db.read { (raw: Database) -> ScheduleState? in
            guard let row = try Row.fetchOne(
                raw, sql: "SELECT schedule FROM card WHERE id = ?", arguments: [cardID.rawValue]
            ) else { return nil }
            let text: String? = row["schedule"]
            guard let text else { return nil }
            return try row.decodePayload(text)
        }
    }

    /// Update the stored schedule for a card (the scheduler owns placement;
    /// the repository just persists it atomically with an attempt when the
    /// caller uses `recordAttempt`).
    public func setSchedule(_ schedule: ScheduleState, cardID: StableID) throws {
        let payload = try Snapshots.canonicalPayload(schedule)
        try mutate(sql: "UPDATE card SET schedule = ? WHERE id = ?",
                   values: [payload, cardID.rawValue],
                   table: "card", id: cardID.rawValue)
    }

    /// Hard-delete a card that carries no attempts. Fails with
    /// `StoreError.foreignKeyFailed` when recorded evidence references it,
    /// or `StoreError.rolledBack` when the card is queued in an active or
    /// interrupted session.
    public func deleteCard(id: StableID) throws {
        try db.write { raw in
            try raw.inSavepoint {
                let inActiveSession = try Bool.fetchOne(raw, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM session, json_each(session.record, '$.cardOrder')
                        WHERE session.status IN ('active', 'interrupted')
                          AND json_each.value = ?
                    );
                    """, arguments: [id.rawValue]) ?? false
                if inActiveSession {
                    throw StoreError.rolledBack(
                        reason: "cannot delete card \(id.rawValue) while queued in an active or interrupted practice session"
                    )
                }
                do {
                    try raw.execute(sql: "DELETE FROM card WHERE id = ?", arguments: [id.rawValue])
                } catch {
                    throw RecallDatabase.mapSQLError(error, table: "card", id: id.rawValue)
                }
                return .commit
            }
        }
    }

    // MARK: - Attempts (append-only)

    /// Append one immutable attempt and move the card's schedule to the
    /// attempt's after-snapshot in the SAME transaction. A payload that
    /// fails domain validation on read is surfaced as corrupt, never
    /// repaired or reinterpreted.
    ///
    /// - Important: session-cursor advance is deliberately NOT part of
    /// this transaction. Use `recordAttempt(_:advancing:)` when the
    /// attempt belongs to a live session so the attempt, schedule, cursor,
    /// and reveal state commit as one durable unit; calling `saveSession`
    /// separately afterwards can double-apply the attempt if the process
    /// dies between the two commits.
    public func recordAttempt(_ attempt: Attempt, applySchedule: Bool = true) throws {
        let snapshot = try Snapshots.AttemptSnapshot(attempt: attempt)
        try db.write { raw in
            try raw.inSavepoint {
                try Self.assertCardBelongsToDeck(raw, attempt: attempt)
                do {
                    try raw.execute(
                        sql: """
                        INSERT INTO attempt (id, card_id, deck_id, timestamp, record, schema_ok)
                        VALUES (?, ?, ?, ?, ?, ?);
                        """,
                        arguments: [snapshot.id, snapshot.cardID, snapshot.deckID,
                                    snapshot.timestamp.timeIntervalSince1970,
                                    snapshot.record, snapshot.schemaOK ? 1 : 0]
                    )
                } catch {
                    throw RecallDatabase.mapSQLError(error, table: "attempt", id: snapshot.id)
                }
                // A corrupt after-snapshot is stored as honest anomaly
                // evidence but must NEVER overwrite the live schedule — an
                // unreadable transition cannot legitimately move a card.
                if applySchedule, snapshot.schemaOK {
                    let payload = try Snapshots.canonicalPayload(attempt.afterSchedule)
                    try raw.execute(
                        sql: "UPDATE card SET schedule = ? WHERE id = ?",
                        arguments: [payload, snapshot.cardID]
                    )
                }
                return .commit
            }
        }
    }

    /// Referential gate for attempts: the named deck must actually own the
    /// named card. Independent `card_id`/`deck_id` foreign keys pass for a
    /// cross-deck attempt, which would be durable but misattributed
    /// evidence, so the pairing is checked inside the same transaction.
    private static func assertCardBelongsToDeck(_ raw: Database, attempt: Attempt) throws {
        let owner: String? = try String.fetchOne(
            raw, sql: "SELECT deck_id FROM card WHERE id = ?",
            arguments: [attempt.cardID.rawValue]
        )
        guard let owner, owner == attempt.deckID.rawValue else {
            throw StoreError.foreignKeyFailed(
                detail: "attempt deck \(attempt.deckID.rawValue) does not own card \(attempt.cardID.rawValue)"
            )
        }
    }

    /// Record an attempt that belongs to a live session and advance that
    /// session — atomically. The attempt row, the card's new schedule, and
    /// the session's post-advance state (cursor, revealed flag, anchors)
    /// all commit or roll back as one unit, so a crash can never leave
    /// durable evidence whose session cursor was never moved (the
    /// double-attempt / double-scheduling window that two separate commits
    /// would leave open).
    public func recordAttempt(_ attempt: Attempt, advancing session: StudySession) throws -> StudySession {
        guard session.status == .active else {
            throw StoreError.invalidSessionAdvance("cannot advance a \(session.status.rawValue) session")
        }
        guard session.cardOrder.indices.contains(session.cursor),
              session.cardOrder[session.cursor] == attempt.cardID else {
            throw StoreError.invalidSessionAdvance(
                "attempt card \(attempt.cardID.rawValue) is not the session's current card"
            )
        }
        guard attempt.deckID == session.deckID else {
            throw StoreError.invalidSessionAdvance(
                "attempt deck \(attempt.deckID.rawValue) is not the session's deck \(session.deckID.rawValue)"
            )
        }
        // A corrupt attempt carries no legitimate schedule transition, and
        // the session path's whole contract is attempt+schedule+cursor
        // committing as one valid unit — reject it up front, before any
        // durable write. (The anomaly belongs in the ledger via the plain
        // `recordAttempt` path, which never applies the schedule.)
        let snapshot = try Snapshots.AttemptSnapshot(attempt: attempt)
        guard snapshot.schemaOK else {
            throw StoreError.corruptRow(table: "attempt", id: attempt.id.rawValue)
        }
        var advanced = session
        advanced.advance() // resets revealed state for the next card
        let sessionSnapshot = try Snapshots.SessionSnapshot(session: advanced)
        try db.write { raw in
            try raw.inSavepoint {
                try Self.assertCardBelongsToDeck(raw, attempt: attempt)
                // Compare-and-advance against the DURABLE session: when a
                // session row already exists, the caller's cursor must
                // still match the stored cursor, so a retry with a stale
                // pre-advance session can never double-apply the same
                // card's attempt and schedule. A session that was never
                // saved is created by this commit (first durable progress
                // point). The revealed flag is deliberately NOT part of
                // the match — it is presentation state the learner flips
                // in memory immediately before grading.
                let durableRow = try Row.fetchOne(raw, sql: """
                    SELECT record, json_extract(record, '$.cursor') AS cursor, status
                    FROM session WHERE id = ?;
                    """, arguments: [session.id.rawValue])
                if let durableRow {
                    let durable: StudySession = try durableRow.domainValue("record")
                    let storedCursor: Int? = durableRow["cursor"]
                    let storedStatus: String = durableRow["status"]
                    guard storedCursor == session.cursor,
                          durable.cardOrder == session.cardOrder,
                          durable.deckID == session.deckID,
                          durable.mode == session.mode,
                          storedStatus == "active" || storedStatus == "interrupted" else {
                        throw StoreError.invalidSessionAdvance(
                            "stored session state no longer matches the caller's (stale or concurrent advance)"
                        )
                    }
                }
                // Compare the schedule inside this transaction, without a
                // nested repository/GRDB read. Another session may have
                // changed it since this pending grade was prepared.
                if let row = try Row.fetchOne(raw, sql: "SELECT schedule FROM card WHERE id = ?",
                                              arguments: [attempt.cardID.rawValue]),
                   let payload: String = row["schedule"] {
                    guard let data = payload.data(using: .utf8),
                          let current = try? JSONDecoder.domain.decode(ScheduleState.self, from: data),
                          current == attempt.beforeSchedule else {
                        throw StoreError.invalidSessionAdvance("stored schedule no longer matches pending grade")
                    }
                }
                do {
                    try raw.execute(
                        sql: """
                        INSERT INTO attempt (id, card_id, deck_id, timestamp, record, schema_ok)
                        VALUES (?, ?, ?, ?, ?, ?);
                        """,
                        arguments: [snapshot.id, snapshot.cardID, snapshot.deckID,
                                    snapshot.timestamp.timeIntervalSince1970,
                                    snapshot.record, snapshot.schemaOK ? 1 : 0]
                    )
                } catch {
                    throw RecallDatabase.mapSQLError(error, table: "attempt", id: snapshot.id)
                }
                let payload = try Snapshots.canonicalPayload(attempt.afterSchedule)
                try raw.execute(
                    sql: "UPDATE card SET schedule = ? WHERE id = ?",
                    arguments: [payload, snapshot.cardID]
                )
                do {
                    try raw.execute(
                        sql: """
                        INSERT INTO session (id, deck_id, status, updated_at, record)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            status = excluded.status,
                            updated_at = excluded.updated_at,
                            record = excluded.record;
                        """,
                        arguments: [sessionSnapshot.id, sessionSnapshot.deckID, sessionSnapshot.status,
                                    sessionSnapshot.updatedAt.timeIntervalSince1970, sessionSnapshot.record]
                    )
                } catch {
                    throw RecallDatabase.mapSQLError(error, table: "session", id: sessionSnapshot.id)
                }
                return .commit
            }
        }
        return advanced
    }

    /// Raw attempt ledger for a card, oldest first. Rows flagged unreadable
    /// at write time, whose payload cannot be decoded, or whose payload
    /// disagrees with the row's indexed card/deck identity throw
    /// `StoreError.corruptRow` so the UI can label the evidence honestly
    /// instead of guessing.
    public func attempts(cardID: StableID) throws -> [Attempt] {
        try db.read { raw in
            try Row.fetchAll(
                raw,
                sql: """
                SELECT id, card_id, deck_id, record, schema_ok FROM attempt
                WHERE card_id = ? ORDER BY timestamp ASC, id ASC
                """,
                arguments: [cardID.rawValue]
            ).map { (row: Row) throws -> Attempt in
                let id: String = row["id"]
                let schemaOK: Int = row["schema_ok"]
                guard schemaOK == 1,
                      let attempt = try Self.decodeAttempt(row: row)
                else { throw StoreError.corruptRow(table: "attempt", id: id) }
                return attempt
            }
        }
    }

    /// Decode an attempt payload and verify it agrees with the row's
    /// indexed identity. A row whose payload decodes but claims a different
    /// card or deck is corrupt, never attributed to the wrong card.
    private static func decodeAttempt(row: Row) throws -> Attempt? {
        let rowCardID: String = row["card_id"]
        let rowDeckID: String = row["deck_id"]
        let text: String = row["record"]
        guard let data = text.data(using: .utf8),
              let attempt = try? JSONDecoder.domain.decode(Attempt.self, from: data),
              attempt.cardID.rawValue == rowCardID,
              attempt.deckID.rawValue == rowDeckID
        else { return nil }
        return attempt
    }

    /// Evidence for the mastery deriver: readable attempts become
    /// `.attempt`, rows flagged unreadable, undecodable, or whose payload
    /// identity disagrees with the row become `.corrupt`, skips become
    /// `.skipped`. Never silently converted to a grade.
    public func evidence(cardID: StableID) throws -> [CardEvidence] {
        try db.read { raw in
            var evidence: [CardEvidence] = []
            let attemptRows = try Row.fetchAll(
                raw,
                sql: """
                SELECT id, card_id, deck_id, record, schema_ok FROM attempt
                WHERE card_id = ? ORDER BY timestamp ASC, id ASC
                """,
                arguments: [cardID.rawValue]
            )
            for row in attemptRows {
                let id: String = row["id"]
                let schemaOK: Int = row["schema_ok"]
                // A row flagged unreadable at write time stays corrupt even
                // if a future codec could parse it.
                if schemaOK == 1, let attempt = try? Self.decodeAttempt(row: row) {
                    evidence.append(.attempt(attempt))
                } else {
                    evidence.append(.corrupt(id: StableID(rawValue: id)))
                }
            }
            let skipRows = try Row.fetchAll(
                raw,
                sql: "SELECT id, timestamp FROM skip WHERE card_id = ? ORDER BY timestamp ASC, id ASC",
                arguments: [cardID.rawValue]
            )
            for row in skipRows {
                let id: String = row["id"]
                evidence.append(.skipped(id: StableID(rawValue: id)))
            }
            return evidence
        }
    }

    // MARK: - Skips (append-only)

    public func recordSkip(cardID: StableID, sessionID: StableID, at instant: Date) throws {
        let id = StableID()
        try db.write { raw in
            do {
                try raw.execute(
                    sql: "INSERT INTO skip (id, card_id, session_id, timestamp) VALUES (?, ?, ?, ?)",
                    arguments: [id.rawValue, cardID.rawValue, sessionID.rawValue,
                                instant.timeIntervalSince1970]
                )
            } catch {
                throw RecallDatabase.mapSQLError(error, table: "skip", id: id.rawValue)
            }
        }
    }

    // MARK: - Sessions

    /// Persist the complete session state (order, cursor, and clock anchors
    /// live inside the record payload). Call this at every durable progress
    /// point so an interrupted app can relaunch from the exact card.
    ///
    /// Session saves are monotonic in durable progress: a save may update
    /// status or clock anchors at the current cursor or move forward, but a
    /// stale in-memory value can NEVER rewind a stored cursor — rewinding
    /// would re-open the double-apply window that the compare-and-advance
    /// guard in `recordAttempt(_:advancing:)` closes. Terminal sessions
    /// (completed/abandoned) are history and are never rewritten.
    public func saveSession(_ session: StudySession) throws {
        let snapshot = try Snapshots.SessionSnapshot(session: session)
        try db.write { raw in
            try raw.inSavepoint {
                let stored = try Row.fetchOne(raw, sql: """
                    SELECT record, status, json_extract(record, '$.cursor') AS cursor
                    FROM session WHERE id = ?;
                    """, arguments: [snapshot.id])
                if let stored {
                    let durable: StudySession = try stored.domainValue("record")
                    guard durable.deckID == session.deckID, durable.mode == session.mode,
                          durable.cardOrder == session.cardOrder else {
                        throw StoreError.invalidSessionAdvance("session deck, mode and order are immutable")
                    }
                    let storedStatus: String = stored["status"]
                    guard storedStatus != "completed", storedStatus != "abandoned" else {
                        throw StoreError.invalidSessionAdvance(
                            "cannot rewrite the \(storedStatus) session \(snapshot.id)"
                        )
                    }
                    let storedCursor: Int? = stored["cursor"]
                    if let storedCursor, session.cursor < storedCursor {
                        throw StoreError.invalidSessionAdvance(
                            "cannot rewind durable session cursor from \(storedCursor) to \(session.cursor)"
                        )
                    }
                }
                do {
                    try raw.execute(
                        sql: """
                        INSERT INTO session (id, deck_id, status, updated_at, record)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            status = excluded.status,
                            updated_at = excluded.updated_at,
                            record = excluded.record;
                        """,
                        arguments: [snapshot.id, snapshot.deckID, snapshot.status,
                                    snapshot.updatedAt.timeIntervalSince1970, snapshot.record]
                    )
                } catch {
                    throw RecallDatabase.mapSQLError(error, table: "session", id: snapshot.id)
                }
                return .commit
            }
        }
    }

    public func session(id: StableID) throws -> StudySession? {
        try db.read { raw in
            guard let row = try Row.fetchOne(raw, sql: "SELECT record FROM session WHERE id = ?", arguments: [id.rawValue]) else {
                return nil
            }
            return try row.domainValue("record")
        }
    }

    /// The resumable session for a deck (active or interrupted), most
    /// recently updated first. Completed/abandoned sessions are history,
    /// not resume targets.
    public func resumableSession(deckID: StableID) throws -> StudySession? {
        try db.read { raw in
            guard let row = try Row.fetchOne(
                raw,
                sql: """
                SELECT record FROM session
                WHERE deck_id = ? AND status IN ('active', 'interrupted')
                ORDER BY updated_at DESC LIMIT 1;
                """,
                arguments: [deckID.rawValue]
            ) else { return nil }
            return try row.domainValue("record")
        }
    }

    // MARK: - Imports (transactional)

    public struct ImportRejection: Equatable, Sendable {
        public let id: StableID
        public let reason: String
    }

    public struct ImportOutcome: Equatable, Sendable {
        /// Card IDs actually persisted.
        public var committed: [StableID]
        /// Card IDs rejected before or during commit (with reasons).
        public var rejected: [ImportRejection]

        public init(committed: [StableID] = [], rejected: [ImportRejection] = []) {
            self.committed = committed
            self.rejected = rejected
        }
    }

    public enum ImportMode: Sendable {
        /// Any validation failure rolls the entire import back.
        case allOrNothing
        /// Invalid rows are reported and skipped; valid rows commit.
        case validRowsOnly
    }

    /// Import cards (with schedules) in ONE transaction.
    ///
    /// Validation runs first (stable-ID duplicates inside the batch,
    /// unknown decks, and cross-deck updates); in `allOrNothing` any
    /// rejection aborts before any row is written. In `validRowsOnly`,
    /// rejections are reported and the remaining rows commit. Either way a
    /// mid-transaction database failure rolls back every prior row of the
    /// same import.
    ///
    /// A card ID that already exists in a DIFFERENT deck is rejected rather
    /// than silently re-parented: the schema only hard-blocks re-parenting
    /// evidenced cards, and an unevidenced card drifting between decks via
    /// a hand-edited CSV is exactly the contamination a strict import must
    /// refuse. Moving a card deliberately is an explicit in-app action.
    @discardableResult
    public func importCards(_ cards: [Card], schedules: [StableID: ScheduleState] = [:],
                            mode: ImportMode = .allOrNothing) throws -> ImportOutcome {
        var outcome = ImportOutcome()
        var seen = Set<String>()
        var valid: [(card: Card, schedule: ScheduleState?)] = []
        try db.read { raw in
            for card in cards {
                if seen.contains(card.id.rawValue) {
                    outcome.rejected.append(.init(id: card.id, reason: "duplicate stable ID in batch"))
                    continue
                }
                seen.insert(card.id.rawValue)
                let owner: String? = try String.fetchOne(
                    raw, sql: "SELECT deck_id FROM card WHERE id = ?",
                    arguments: [card.id.rawValue]
                )
                if let owner, owner != card.deckID.rawValue {
                    outcome.rejected.append(.init(id: card.id,
                                                  reason: "card exists in another deck (\(owner)); refusing silent re-parent"))
                    continue
                }
                let deckExists = try Bool.fetchOne(
                    raw, sql: "SELECT EXISTS(SELECT 1 FROM deck WHERE id = ?)",
                    arguments: [card.deckID.rawValue]
                ) ?? false
                if !deckExists {
                    outcome.rejected.append(.init(id: card.id, reason: "unknown deck \(card.deckID.rawValue)"))
                    continue
                }
                valid.append((card, schedules[card.id]))
            }
        }
        if mode == .allOrNothing, !outcome.rejected.isEmpty {
            return outcome // nothing written — pre-validation stopped the batch
        }
        do {
            try db.write { raw in
                try raw.inSavepoint {
                    for entry in valid {
                        let snapshot = try Snapshots.CardSnapshot(card: entry.card, schedule: entry.schedule)
                        try raw.execute(
                            sql: """
                            INSERT INTO card (id, deck_id, sort_order, is_archived, created_at, updated_at, record, schedule)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET
                                deck_id = excluded.deck_id,
                                sort_order = excluded.sort_order,
                                is_archived = excluded.is_archived,
                                updated_at = excluded.updated_at,
                                record = excluded.record,
                                schedule = COALESCE(excluded.schedule, card.schedule);
                            """,
                            arguments: [snapshot.id, snapshot.deckID, snapshot.sortOrder,
                                        snapshot.isArchived ? 1 : 0,
                                        snapshot.createdAt.timeIntervalSince1970,
                                        snapshot.updatedAt.timeIntervalSince1970,
                                        snapshot.record, snapshot.schedule]
                        )
                        outcome.committed.append(entry.card.id)
                    }
                    return .commit
                }
            }
        } catch {
            // Savepoint rolled back; undo the committed list honestly.
            outcome.committed.removeAll()
            throw StoreError.rolledBack(reason: String(describing: error))
        }
        return outcome
    }

    /// Restore decks, cards, and schedules from a decoded backup in ONE
    /// transaction. This is the persistence half of the user-owned backup
    /// story (the versioned JSON codec ships separately): a restore file
    /// lists decks first, then cards that reference them.
    ///
    /// Validation runs before any write: decks referencing nothing and
    /// cards referencing an unknown deck (neither in the database nor in
    /// the same batch) are rejected; duplicate stable IDs inside the batch
    /// are rejected. In `allOrNothing` any rejection aborts the entire
    /// restore with nothing written; in `validRowsOnly` rejections are
    /// reported and valid rows commit. A database failure mid-transaction
    /// rolls back every row of the restore and throws
    /// `StoreError.rolledBack` — a partially restored database is never
    /// left behind.
    ///
    /// Attempts, skips, and sessions are append-only evidence and are
    /// intentionally NOT restorable from a file: history can only be
    /// appended by the learner actually practicing.
    @discardableResult
    public func restore(decks: [Deck] = [], cards: [Card] = [],
                        schedules: [StableID: ScheduleState] = [:],
                        mode: ImportMode = .allOrNothing) throws -> ImportOutcome {
        var outcome = ImportOutcome()
        var validDecks: [Deck] = []
        var validCards: [Card] = []

        try db.read { raw in
            var seenDecks = Set<String>()
            for deck in decks {
                if seenDecks.contains(deck.id.rawValue) {
                    outcome.rejected.append(.init(id: deck.id, reason: "duplicate deck ID in batch"))
                    continue
                }
                seenDecks.insert(deck.id.rawValue)
                validDecks.append(deck)
            }
            var seenCards = Set<String>()
            for card in cards {
                if seenCards.contains(card.id.rawValue) {
                    outcome.rejected.append(.init(id: card.id, reason: "duplicate card ID in batch"))
                    continue
                }
                seenCards.insert(card.id.rawValue)
                let deckExists = try Bool.fetchOne(
                    raw, sql: "SELECT EXISTS(SELECT 1 FROM deck WHERE id = ?)",
                    arguments: [card.deckID.rawValue]
                ) ?? false
                if !deckExists && !seenDecks.contains(card.deckID.rawValue) {
                    outcome.rejected.append(.init(id: card.id, reason: "unknown deck \(card.deckID.rawValue)"))
                    continue
                }
                validCards.append(card)
            }
        }
        if mode == .allOrNothing, !outcome.rejected.isEmpty {
            return outcome // nothing written — pre-validation stopped the batch
        }
        do {
            try db.write { raw in
                try raw.inSavepoint {
                    for deck in validDecks {
                        let snapshot = Snapshots.DeckSnapshot(deck: deck)
                        try raw.execute(
                            sql: """
                            INSERT INTO deck (id, title, is_archived, created_at, updated_at, record)
                            VALUES (?, ?, ?, ?, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET
                                title = excluded.title,
                                is_archived = excluded.is_archived,
                                updated_at = excluded.updated_at,
                                record = excluded.record;
                            """,
                            arguments: [snapshot.id, snapshot.title, snapshot.isArchived ? 1 : 0,
                                        snapshot.createdAt.timeIntervalSince1970,
                                        snapshot.updatedAt.timeIntervalSince1970,
                                        try Snapshots.canonicalPayload(deck)]
                        )
                        outcome.committed.append(deck.id)
                    }
                    for card in validCards {
                        let snapshot = try Snapshots.CardSnapshot(card: card, schedule: schedules[card.id])
                        try raw.execute(
                            sql: """
                            INSERT INTO card (id, deck_id, sort_order, is_archived, created_at, updated_at, record, schedule)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET
                                deck_id = excluded.deck_id,
                                sort_order = excluded.sort_order,
                                is_archived = excluded.is_archived,
                                updated_at = excluded.updated_at,
                                record = excluded.record,
                                schedule = COALESCE(excluded.schedule, card.schedule);
                            """,
                            arguments: [snapshot.id, snapshot.deckID, snapshot.sortOrder,
                                        snapshot.isArchived ? 1 : 0,
                                        snapshot.createdAt.timeIntervalSince1970,
                                        snapshot.updatedAt.timeIntervalSince1970,
                                        snapshot.record, snapshot.schedule]
                        )
                        outcome.committed.append(card.id)
                    }
                    return .commit
                }
            }
        } catch {
            // Savepoint rolled back; undo the committed list honestly.
            outcome.committed.removeAll()
            throw StoreError.rolledBack(reason: String(describing: error))
        }
        return outcome
    }

    // MARK: - Integrity & reset

    /// SQLite's own structural health checks. Returns `"ok"` and `"ok"` on
    /// a healthy database.
    public func integrityReport() throws -> [String] {
        try db.read { raw in
            var report: [String] = []
            report.append(try String.fetchOne(raw, sql: "PRAGMA integrity_check") ?? "no result")
            let fkViolations = try Row.fetchAll(raw, sql: "PRAGMA foreign_key_check")
            report.append(fkViolations.isEmpty ? "ok" : "foreign_key_check: \(fkViolations.count) violations")
            return report
        }
    }

    /// Irreversibly erase every row the user owns — decks, cards,
    /// schedules, attempt ledger, skips, sessions — inside ONE immediate
    /// transaction. The append-only DELETE triggers are dropped and
    /// re-created within that same transaction, so the evidence invariant
    /// holds across the whole statement: there is never a committed state
    /// where evidence rows exist unprotected, and any failure rolls the
    /// reset (and the trigger drop) back together.
    public func resetAll() throws {
        // writeWithoutTransaction: the BEGIN IMMEDIATE below IS the
        // transaction; GRDB must not wrap it in another one.
        try db.writeWithoutTransaction { raw in
            try raw.execute(sql: "BEGIN IMMEDIATE;")
            do {
                try raw.execute(sql: "DROP TRIGGER attempt_no_delete;")
                try raw.execute(sql: "DROP TRIGGER skip_no_delete;")
                try raw.execute(sql: """
                    DELETE FROM attempt;
                    DELETE FROM skip;
                    DELETE FROM session;
                    DELETE FROM card;
                    DELETE FROM deck;
                    """)
                try RecallDatabaseMigrator.installDeleteTriggers(raw)
                try raw.execute(sql: "COMMIT;")
            } catch {
                try? raw.execute(sql: "ROLLBACK;")
                throw error
            }
        }
    }

    /// The "delete all my data" path. `resetAll()` erases every row through
    /// the trigger-safe transaction; with a file URL, the connection is
    /// then CLOSED before the database file and its WAL/SHM sidecars are
    /// removed, so the repository is left in a definitively closed state
    /// rather than holding a ghost handle to an unlinked file. Callers on
    /// the reset path should discard this repository and open a fresh one
    /// (or terminate the app).
    ///
    /// On an in-memory database pass no URL — there is no file to unlink,
    /// only rows to erase.
    public func deleteAllData(at url: URL?, fileManager: FileManager = .default) throws {
        try resetAll()
        guard let url else { return }
        try db.close()
        try RecallDatabase.unlinkDatabase(at: url, fileManager: fileManager)
    }

    // MARK: - Internal helpers

    private func mutate(sql: String, values: [DatabaseValueConvertible?],
                        table: String, id: String) throws {
        try db.write { raw in
            do {
                try raw.execute(sql: sql, arguments: StatementArguments(values))
            } catch {
                throw RecallDatabase.mapSQLError(error, table: table, id: id)
            }
        }
    }
}
