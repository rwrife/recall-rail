import Foundation

/// Why a card appears in a due queue, or why it does not.
///
/// The scheduler explains itself; the UI shows this reason instead of an
/// opaque "due" badge.
public struct DueReason: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// No attempt has ever been recorded; shown as new/unknown, not due-by-mastery.
        case neverSeen
        /// Due because the schedule window elapsed.
        case dueElapsed
        /// Not due yet.
        case notDue
    }

    public let kind: Kind
    /// The schedule snapshot the reason was computed from.
    public let schedule: ScheduleState
    /// The instant the question was asked.
    public let evaluatedAt: Date

    public init(kind: Kind, schedule: ScheduleState, evaluatedAt: Date) {
        self.kind = kind
        self.schedule = schedule
        self.evaluatedAt = evaluatedAt
    }
}

/// Errors the scheduler raises instead of inventing a transition.
public enum SchedulingError: Error, Equatable, Sendable {
    /// The state's algorithm version has no checked-in rule table.
    case unsupportedAlgorithmVersion(Int)
    /// No rule row exists for the (grade, box) pair — a rule-table gap.
    case missingRule(grade: Grade, fromBox: Int)
    /// The state's box is off the ladder defined by the rule table.
    case boxOutOfRange(Int)
}

/// Deterministic, explainable Leitner scheduler.
///
/// All date arithmetic is civil-calendar arithmetic in a fixed calendar
/// identifier (Gregorian) at the UTC timezone offset of the injected clock's
/// reference — intervals count in *civil days*, so a due time crossing a DST
/// boundary lands at the same wall-clock time in the card's calendar rather
/// than shifting by an hour. Instants are compared absolutely, so DST never
/// silently changes *whether* something is due, only which civil day it
/// belongs to.
public struct LeitnerScheduler: Sendable {
    public let algorithmVersion: Int
    /// Calendar used for civil-day addition. Gregorian + current time zone
    /// gives stable wall-clock semantics across DST transitions.
    private let calendar: Calendar

    public init(algorithmVersion: Int = 1, calendar: Calendar? = nil) {
        self.algorithmVersion = algorithmVersion
        if let calendar {
            self.calendar = calendar
        } else {
            var derived = Calendar(identifier: .gregorian)
            derived.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            self.calendar = derived
        }
    }

    /// Apply a grade to a schedule state at an instant and return the new
    /// state. Throws instead of guessing when the table does not cover the
    /// input — unknown versions and off-ladder boxes are errors, not
    /// fallbacks to box 1.
    public func apply(
        grade: Grade,
        to state: ScheduleState,
        at instant: Date,
        attemptID: StableID
    ) throws -> ScheduleState {
        try validate(state)
        guard let row = SchedulingRules.rule(version: algorithmVersion, grade: grade, fromBox: state.box) else {
            throw SchedulingError.missingRule(grade: grade, fromBox: state.box)
        }
        let dueAt: Date
        if row.intervalDays == 0 {
            dueAt = instant
        } else {
            // Civil-day addition: DST-safe. Adding 1 civil day across a DST
            // transition keeps the wall-clock time stable.
            dueAt = calendar.date(byAdding: .day, value: row.intervalDays, to: instant) ?? instant
        }
        let streak: Int
        switch row.recallCounterEffect {
        case .reset: streak = 0
        case .increment: streak = state.consecutiveRecalls + 1
        }
        return ScheduleState(
            box: row.toBox,
            dueAt: dueAt,
            consecutiveRecalls: streak,
            lastAttemptID: attemptID,
            algorithmVersion: algorithmVersion
        )
    }

    /// Query paths validate too; an unsupported schedule must not produce
    /// a guessed due queue or a confident UI explanation.
    public func validate(_ state: ScheduleState) throws {
        guard state.algorithmVersion == algorithmVersion else {
            throw SchedulingError.unsupportedAlgorithmVersion(state.algorithmVersion)
        }
        guard (1...SchedulingRules.maxBox).contains(state.box) else {
            throw SchedulingError.boxOutOfRange(state.box)
        }
    }

    /// Explain why (or why not) a card appears due at an instant.
    public func dueReason(for state: ScheduleState, at instant: Date) -> DueReason {
        if state.lastAttemptID == nil {
            return DueReason(kind: .neverSeen, schedule: state, evaluatedAt: instant)
        }
        // Absolute instant comparison — DST changes cannot flip this.
        if instant >= state.dueAt {
            return DueReason(kind: .dueElapsed, schedule: state, evaluatedAt: instant)
        }
        return DueReason(kind: .notDue, schedule: state, evaluatedAt: instant)
    }
}
