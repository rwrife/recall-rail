import Foundation
import GRDB
import RecallRailKit

/// Minimal, validating snapshots of the JSON payload columns.
///
/// The authoritative record for each row is its full domain `record` JSON;
/// snapshot columns exist only to carry the few fields the engine needs for
/// queries and integrity. Every payload is canonicalized through a strict
/// encode/decode round-trip before it is stored, so a value that cannot
/// survive serialization verbatim fails the write instead of persisting a
/// row that would later decode differently.
enum Snapshots {
    /// Canonical payload text (sorted keys, numeric dates), validated by a
    /// strict decode round-trip against the original value.
    static func canonicalPayload<T: Codable & Equatable>(_ value: T) throws -> String {
        let data = try JSONEncoder.domain.encode(value)
        guard (try? JSONDecoder.domain.decode(T.self, from: data)) == value else {
            throw StoreEncodeError.snapshotMismatch(String(describing: T.self))
        }
        return String(decoding: data, as: UTF8.self)
    }

    struct DeckSnapshot {
        let id: String
        let title: String
        let isArchived: Bool
        let createdAt: Date
        let updatedAt: Date

        init(deck: Deck) {
            id = deck.id.rawValue
            title = deck.title
            isArchived = deck.isArchived
            createdAt = deck.createdAt
            updatedAt = deck.updatedAt
        }
    }

    struct CardSnapshot {
        let id: String
        let deckID: String
        let sortOrder: Int
        let isArchived: Bool
        let createdAt: Date
        let updatedAt: Date
        let record: String  // canonical JSON of the Card
        let schedule: String?  // canonical JSON of the ScheduleState

        init(card: Card, schedule: ScheduleState?) throws {
            id = card.id.rawValue
            deckID = card.deckID.rawValue
            sortOrder = card.sortOrder
            isArchived = card.isArchived
            createdAt = card.createdAt
            updatedAt = card.updatedAt
            record = try Snapshots.canonicalPayload(card)
            self.schedule = try schedule.map(Snapshots.canonicalPayload)
        }
    }

    struct AttemptSnapshot {
        let id: String
        let cardID: String
        let deckID: String
        let timestamp: Date
        let schemaOK: Bool
        let record: String

        init(attempt: Attempt) throws {
            id = attempt.id.rawValue
            cardID = attempt.cardID.rawValue
            deckID = attempt.deckID.rawValue
            timestamp = attempt.timestamp
            // An attempt whose snapshots leave the ladder or whose elapsed
            // time is negative can be *stored* (honest evidence of an
            // anomaly) but is flagged so the ledger surfaces it as corrupt
            // rather than readable evidence.
            let readable = (1...SchedulingRules.maxBox).contains(attempt.beforeSchedule.box)
                && (1...SchedulingRules.maxBox).contains(attempt.afterSchedule.box)
                && attempt.elapsedMilliseconds >= 0
                && !SchedulingRules.rows(version: attempt.algorithmVersion).isEmpty
            schemaOK = readable
            record = try Snapshots.canonicalPayload(attempt)
        }
    }

    struct SessionSnapshot {
        let id: String
        let deckID: String
        let status: String
        let updatedAt: Date
        let record: String

        init(session: StudySession) throws {
            id = session.id.rawValue
            deckID = session.deckID.rawValue
            status = session.status.rawValue
            updatedAt = session.endedAt ?? session.startedAt
            record = try Snapshots.canonicalPayload(session)
        }
    }
}

public enum StoreEncodeError: Error, Equatable {
    case snapshotMismatch(String)
}

extension JSONEncoder {
    /// Canonical encoder used for every persisted payload: stable numeric
    /// dates (lossless across sub-second precision; ISO-8601 truncates to
    /// whole seconds), sorted keys so stored JSON text is byte-deterministic.
    static var domain: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var domain: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

public enum StoreDecomposeError: Error, Equatable {
    case invalidPayload(String)
}

extension Row {
    /// Decode a domain value from a column holding canonical payload text.
    func domainValue<T: Decodable>(_ column: String) throws -> T {
        let text: String? = self[column]
        guard let text else {
            throw StoreDecomposeError.invalidPayload(column)
        }
        return try decodePayload(text, column: column)
    }

    func decodePayload<T: Decodable>(_ text: String, column: String = "payload") throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw StoreDecomposeError.invalidPayload(column)
        }
        do {
            return try JSONDecoder.domain.decode(T.self, from: data)
        } catch {
            throw StoreDecomposeError.invalidPayload(column)
        }
    }
}
