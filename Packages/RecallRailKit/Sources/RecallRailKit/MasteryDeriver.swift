import Foundation

/// One unit of evidence about a card as the repository layer can present it.
///
/// Real attempts are the only evidence that can move mastery. Skipped cards,
/// missing rows, imported-without-history placeholders, and corrupt records
/// are represented explicitly so the deriver can refuse to read them as
/// either success or failure.
public enum CardEvidence: Equatable, Identifiable, Sendable {
    /// A graded attempt recorded by the app.
    case attempt(Attempt)
    /// The learner skipped the card during a session.
    case skipped(id: StableID)
    /// A card was expected to have evidence at a position but none exists.
    case missing(id: StableID)
    /// A card arrived via import with no attempt history attached.
    case importedWithoutHistory(id: StableID)
    /// Stored evidence failed integrity/decoding checks and cannot be read.
    case corrupt(id: StableID)

    public var id: StableID {
        switch self {
        case .attempt(let a): return a.id
        case .skipped(let id), .missing(let id), .importedWithoutHistory(let id), .corrupt(let id):
            return id
        }
    }
}

/// App-observed mastery state derived from evidence. Never asserted directly
/// by users or by the scheduler, and never a claim about objective mastery.
public enum MasteryState: String, Codable, CaseIterable, Sendable {
    /// No evidence of any kind exists for the card.
    case unseen
    /// Evidence exists but none of it is readable grade evidence — skipped,
    /// imported-without-history, missing, or corrupt records land here, not
    /// in a success or failure bucket.
    case insufficientEvidence
    /// Readable attempts exist and the card is due now.
    case due
    /// Readable attempts exist, the card is not due, and the most recent
    /// readable grade was a clean recall.
    case recentlyRecalled
    /// Readable attempts exist, the card is not due, and it is still working
    /// toward reliable recall.
    case learning
}

/// Derives mastery states from evidence without ever converting absent,
/// skipped, or corrupt records into a grade.
public struct MasteryDeriver: Sendable {
    public let scheduler: LeitnerScheduler

    public init(scheduler: LeitnerScheduler) {
        self.scheduler = scheduler
    }

    /// The live schedule's identity is authoritative for a stored card.
    /// Wall-clock ordering alone cannot identify the last durable attempt
    /// after a clock edit. Missing/mismatched evidence stays insufficient.
    public func derive(evidence: [CardEvidence], currentSchedule: ScheduleState, at instant: Date) -> MasteryState {
        guard let id = currentSchedule.lastAttemptID else {
            return evidence.isEmpty ? .unseen : .insufficientEvidence
        }
        guard !evidence.contains(where: {
            if case .corrupt = $0 { return true }
            if case .missing = $0 { return true }
            return false
        }), let latest = evidence.compactMap({ item -> Attempt? in
            if case .attempt(let attempt) = item, attempt.id == id { return attempt }
            return nil
        }).first, isReadable(latest), latest.afterSchedule == currentSchedule else {
            return .insufficientEvidence
        }
        if instant >= currentSchedule.dueAt { return .due }
        return latest.grade == .recalled ? .recentlyRecalled : .learning
    }

    /// Deterministic ordering of evidence: wall-clock timestamp, then the
    /// monotonic start anchor (immune to wall-clock edits), then a stable ID
    /// tie-break so equal instants still produce one total order.
    public static func orderedEvidence(_ evidence: [CardEvidence]) -> [CardEvidence] {
        evidence.sorted { lhs, rhs in
            let lhsKey = sortKey(lhs)
            let rhsKey = sortKey(rhs)
            if lhsKey.timestamp != rhsKey.timestamp { return lhsKey.timestamp < rhsKey.timestamp }
            if lhsKey.monotonic != rhsKey.monotonic { return lhsKey.monotonic < rhsKey.monotonic }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private static func sortKey(_ evidence: CardEvidence) -> (timestamp: Date, monotonic: UInt64) {
        switch evidence {
        case .attempt(let a):
            return (a.timestamp, a.monotonicStartNanos)
        case .skipped, .missing, .importedWithoutHistory, .corrupt:
            // Structural markers carry no instant; they sort before graded
            // evidence at the same timestamp position via Date(0).
            return (Date(timeIntervalSince1970: 0), 0)
        }
    }

    /// Derive the mastery state for one card's evidence at an instant.
    public func derive(evidence: [CardEvidence], at instant: Date) -> MasteryState {
        let ordered = Self.orderedEvidence(evidence)
        let attempts = ordered.compactMap { item -> Attempt? in
            if case .attempt(let a) = item, isReadable(a) { return a }
            return nil
        }
        if attempts.isEmpty {
            // Zero readable evidence: a card with no trace at all is unseen;
            // anything that left a non-grade trace (skip, import, corruption)
            // is explicitly insufficient, never silently "learning" or
            // "failed".
            return ordered.isEmpty ? .unseen : .insufficientEvidence
        }
        // The newest readable attempt carries the schedule snapshot; the
        // after-snapshot is the card's current state.
        let latest = attempts[attempts.count - 1]
        let reason = scheduler.dueReason(for: latest.afterSchedule, at: instant)
        if reason.kind == .dueElapsed {
            return .due
        }
        return latest.grade == .recalled ? .recentlyRecalled : .learning
    }

    /// A readable attempt is one whose snapshots stay on the ladder and
    /// whose elapsed time is non-negative. Callers may also map undecodable
    /// rows to `.corrupt` before they reach here; the guard is a second line
    /// of defense so corrupt data derives `insufficientEvidence`, never a
    /// grade.
    private func isReadable(_ attempt: Attempt) -> Bool {
        guard (1...SchedulingRules.maxBox).contains(attempt.beforeSchedule.box),
              (1...SchedulingRules.maxBox).contains(attempt.afterSchedule.box),
              attempt.elapsedMilliseconds >= 0,
              SchedulingRules.rows(version: attempt.algorithmVersion).isEmpty == false
        else { return false }
        return true
    }
}
