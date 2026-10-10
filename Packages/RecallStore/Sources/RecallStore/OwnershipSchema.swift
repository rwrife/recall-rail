import Foundation
import CoreFoundation
import RecallRailKit

/// Validate JSON shape before Decodable can discard unknown nested fields.
enum OwnershipSchema {
    static let fields: [String: Set<String>] = [
        "deck": ["id", "title", "notes", "tags", "isArchived", "createdAt", "updatedAt"],
        "card": ["id", "deckID", "prompt", "answer", "hint", "source", "tags", "sortOrder", "isArchived", "createdAt", "updatedAt"],
        "schedule": ["box", "dueAt", "consecutiveRecalls", "lastAttemptID", "algorithmVersion"],
        "attempt": ["id", "cardID", "deckID", "timestamp", "monotonicStartNanos", "monotonicEndNanos", "elapsedMilliseconds", "grade", "mode", "beforeSchedule", "afterSchedule", "algorithmVersion", "clockProvenance"],
        "session": ["id", "deckID", "cardOrder", "cursor", "mode", "status", "isRevealed", "startedAt", "endedAt", "monotonicStartNanos", "monotonicCheckpointNanos", "currentCardElapsedNanos", "clockProvenance"]
    ]
    static func validate(_ text: String, kind: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw OwnershipError.invalid("Invalid domain object") }
        try validate(object, kind: kind)
    }
    static func validate(_ object: [String: Any], kind: String) throws {
        guard let allowed = fields[kind], Set(object.keys).isSubset(of: allowed) else { throw OwnershipError.invalid("Unknown domain fields") }
        for (key, value) in object {
            if value is NSNull { continue } // Decodable checks required/null fields.
            if ["id", "deckID", "cardID", "lastAttemptID"].contains(key) {
                try identifier(value)
            } else if key == "cardOrder" {
                guard let ids = value as? [Any], ids.count <= BackupCodec.maximumRows else { throw OwnershipError.invalid("Invalid card order") }
                for id in ids { try identifier(id) }
            } else if ["beforeSchedule", "afterSchedule"].contains(key) {
                guard let nested = value as? [String: Any] else { throw OwnershipError.invalid("Invalid nested schedule") }
                try validate(nested, kind: "schedule")
            } else if ["createdAt", "updatedAt", "dueAt", "timestamp", "startedAt", "endedAt"].contains(key) {
                let seconds: Double
                if let text = value as? String, text.hasPrefix("ref:"), let bits = UInt64(text.dropFirst(4), radix: 16) {
                    seconds = Double(bitPattern: bits) + Date.timeIntervalBetween1970AndReferenceDate
                } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    seconds = number.doubleValue
                } else { throw OwnershipError.invalid("Invalid domain date") }
                guard seconds.isFinite, abs(seconds) <= 1_000_000_000_000 else { throw OwnershipError.invalid("Domain date out of bounds") }
            } else if ["sortOrder", "consecutiveRecalls", "cursor", "elapsedMilliseconds"].contains(key) {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0, number.doubleValue <= 1_000_000_000, number.doubleValue.rounded() == number.doubleValue else { throw OwnershipError.invalid("Domain counter out of bounds") }
            }
        }
    }
    static func identifier(_ value: Any) throws {
        guard let raw = value as? String, UUID(uuidString: raw) != nil else { throw OwnershipError.invalid("Invalid nested ID") }
    }
    static func scheduleValid(_ value: ScheduleState) -> Bool {
        (1...SchedulingRules.maxBox).contains(value.box) && (0...1_000_000_000).contains(value.consecutiveRecalls) && !SchedulingRules.rows(version: value.algorithmVersion).isEmpty && value.dueAt.timeIntervalSince1970.isFinite && abs(value.dueAt.timeIntervalSince1970) <= 1_000_000_000_000
    }
}
