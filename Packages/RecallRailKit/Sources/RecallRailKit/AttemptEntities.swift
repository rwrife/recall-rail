import Foundation

/// Where a card sits in the Leitner ladder and when it is next due.
///
/// `ScheduleState` is a value snapshot: attempts store their own before/after
/// copies so history never rewrites itself when the algorithm is upgraded.
public struct ScheduleState: Codable, Equatable, Sendable {
    /// 1-based Leitner box. Box 1 is the learning box; the ladder length is
    /// defined by the rule table, not by this struct.
    public var box: Int
    /// The instant at which the card becomes due. A card is due when
    /// `now >= dueAt`.
    public var dueAt: Date
    /// Consecutive clean `recalled` grades since the last `again` or `hard`.
    public var consecutiveRecalls: Int
    /// The most recent attempt that produced this state, when one exists.
    public var lastAttemptID: StableID?
    /// Algorithm version whose rules produced this state. Never mutated in
    /// place across versions.
    public var algorithmVersion: Int

    public init(
        box: Int,
        dueAt: Date,
        consecutiveRecalls: Int = 0,
        lastAttemptID: StableID? = nil,
        algorithmVersion: Int
    ) {
        self.box = box
        self.dueAt = dueAt
        self.consecutiveRecalls = consecutiveRecalls
        self.lastAttemptID = lastAttemptID
        self.algorithmVersion = algorithmVersion
    }

    /// Fresh state for a brand-new card: first box, immediately due.
    public static func initial(at instant: Date, algorithmVersion: Int) -> ScheduleState {
        ScheduleState(
            box: 1,
            dueAt: instant,
            consecutiveRecalls: 0,
            lastAttemptID: nil,
            algorithmVersion: algorithmVersion
        )
    }
}

/// One immutable practice attempt. Attempts are append-only evidence; they
/// carry their own schedule snapshots so the ledger is self-describing even
/// after algorithm upgrades.
public struct Attempt: Codable, Equatable, Identifiable, Sendable {
    public let id: StableID
    public let cardID: StableID
    public let deckID: StableID
    /// Wall-clock instant the grade was committed, from the injected clock.
    public let timestamp: Date
    /// Monotonic nanosecond anchor at attempt start, for honest elapsed time
    /// across interruptions and wall-clock changes.
    public let monotonicStartNanos: UInt64
    /// Monotonic nanosecond anchor at attempt commit.
    public let monotonicEndNanos: UInt64
    public let elapsedMilliseconds: Int
    public let grade: Grade
    public let mode: PracticeMode
    public let beforeSchedule: ScheduleState
    public let afterSchedule: ScheduleState
    public let algorithmVersion: Int

    public init(
        id: StableID = StableID(),
        cardID: StableID,
        deckID: StableID,
        timestamp: Date,
        monotonicStartNanos: UInt64,
        monotonicEndNanos: UInt64,
        grade: Grade,
        mode: PracticeMode,
        beforeSchedule: ScheduleState,
        afterSchedule: ScheduleState,
        algorithmVersion: Int
    ) {
        self.id = id
        self.cardID = cardID
        self.deckID = deckID
        self.timestamp = timestamp
        self.monotonicStartNanos = monotonicStartNanos
        self.monotonicEndNanos = monotonicEndNanos
        let delta = monotonicEndNanos >= monotonicStartNanos
            ? monotonicEndNanos - monotonicStartNanos
            : 0
        self.elapsedMilliseconds = Int(min(delta / 1_000_000, UInt64(Int.max)))
        self.grade = grade
        self.mode = mode
        self.beforeSchedule = beforeSchedule
        self.afterSchedule = afterSchedule
        self.algorithmVersion = algorithmVersion
    }
}

/// Interruption-safe practice session state.
///
/// A session stores its ordered card IDs and a cursor so the app can persist
/// and restore it after backgrounding or termination without re-deriving
/// order from volatile state. Both clock anchors are recorded so resume can
/// tell real elapsed time apart from a changed wall clock.
public struct StudySession: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, CaseIterable, Sendable {
        case active
        case interrupted
        case completed
        case abandoned
    }

    public let id: StableID
    public let deckID: StableID
    /// Stable ordering of cards for this run; never reordered mid-session.
    public var cardOrder: [StableID]
    /// Index into `cardOrder` of the next card to present.
    public var cursor: Int
    public let mode: PracticeMode
    public var status: Status
    /// Whether the answer for the current card has been revealed. Persisted
    /// with the session so a relaunch restores exactly what the learner was
    /// looking at — neither re-hiding the answer nor revealing it early.
    public var isRevealed: Bool
    public let startedAt: Date
    /// Set when the session was interrupted or finished.
    public var endedAt: Date?
    public let monotonicStartNanos: UInt64
    /// Monotonic anchor at the most recent durable progress point, used to
    /// resume honest elapsed timing after interruptions.
    public var monotonicCheckpointNanos: UInt64

    public init(
        id: StableID = StableID(),
        deckID: StableID,
        cardOrder: [StableID],
        cursor: Int = 0,
        mode: PracticeMode,
        status: Status = .active,
        isRevealed: Bool = false,
        startedAt: Date,
        endedAt: Date? = nil,
        monotonicStartNanos: UInt64,
        monotonicCheckpointNanos: UInt64
    ) {
        self.id = id
        self.deckID = deckID
        self.cardOrder = cardOrder
        self.cursor = cursor
        self.mode = mode
        self.status = status
        self.isRevealed = isRevealed
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.monotonicStartNanos = monotonicStartNanos
        self.monotonicCheckpointNanos = monotonicCheckpointNanos
    }

    /// The card currently in front of the learner, if the session has one.
    public var currentCardID: StableID? {
        guard cursor >= 0, cursor < cardOrder.count else { return nil }
        return cardOrder[cursor]
    }

    /// Mark the session interrupted, recording wall and monotonic anchors so
    /// resume can restore without double-writing an attempt.
    public mutating func interrupt(at instant: Date, monotonicNanos: UInt64) {
        status = .interrupted
        endedAt = instant
        monotonicCheckpointNanos = monotonicNanos
    }

    /// Resume an interrupted session at a new instant. Cursor and card order
    /// are untouched, so the card in front of the learner is preserved.
    public mutating func resume(at instant: Date, monotonicNanos: UInt64) {
        precondition(status == .interrupted, "only interrupted sessions resume")
        status = .active
        endedAt = nil
        monotonicCheckpointNanos = monotonicNanos
        _ = instant
    }

    /// Real elapsed nanoseconds between a monotonic anchor and `now`,
    /// clamped to zero. A device reboot restarts the monotonic counter, so
    /// a post-reboot reading can be numerically smaller than a stored
    /// anchor; honest elapsed time is then unknown — never negative and
    /// never a bogus full-counter difference.
    public static func elapsedNanos(from anchor: UInt64, to now: UInt64) -> UInt64 {
        now >= anchor ? now - anchor : 0
    }

    /// Advance to the next card after a durable attempt was recorded. The
    /// next card starts unrevealed — the learner must reveal it themselves.
    public mutating func advance() {
        guard status == .active else { return }
        cursor += 1
        isRevealed = false
        if cursor >= cardOrder.count {
            status = .completed
        }
    }
}
