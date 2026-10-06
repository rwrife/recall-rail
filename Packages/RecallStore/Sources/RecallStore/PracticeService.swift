import Foundation
import RecallRailKit

/// The production practice path. Grades are volatile until explicit Next;
/// reveal/order/cursor are durable. Clean interruptions retain measured
/// foreground time; resume restarts the uncheckpointed segment, and a
/// backwards uptime counter conservatively resets current-card timing.
public struct PracticeService: Sendable {
    public private(set) var session: StudySession
    public private(set) var pending: Attempt?
    private var cardAnchor: UInt64
    private var accumulatedNanos: UInt64

    private init(session: StudySession, nanos: UInt64) {
        self.session = session
        self.cardAnchor = nanos
        self.accumulatedNanos = session.currentCardElapsedNanos ?? 0
    }

    public static func start(repo: RecallRepository, deckID: StableID, selection: PracticeSelection,
                             mode: PracticeMode, at instant: Date, nanos: UInt64) throws -> Self {
        guard let deck = try repo.deck(id: deckID), !deck.isArchived else { throw PracticeError.emptyQueue }
        if try repo.resumableSession(deckID: deckID) != nil { throw PracticeError.staleSession }
        let cards = try repo.cards(deckID: deckID)
        var schedules: [StableID: ScheduleState] = [:]
        for card in cards { schedules[card.id] = try repo.practiceSchedule(for: card) }
        let order = try selection.order(cards: cards, schedules: schedules, at: instant)
        guard !order.isEmpty else { throw PracticeError.emptyQueue }
        let session = StudySession(deckID: deckID, cardOrder: order, mode: mode, startedAt: instant,
                                   monotonicStartNanos: nanos, monotonicCheckpointNanos: nanos)
        try repo.saveSession(session)
        return Self(session: session, nanos: nanos)
    }

    public static func resume(repo: RecallRepository, session: StudySession, at instant: Date, nanos: UInt64) throws -> Self {
        guard let durable = try repo.session(id: session.id), durable == session,
              durable.status == .active || durable.status == .interrupted else { throw PracticeError.staleSession }
        var active = durable
        if nanos < durable.monotonicCheckpointNanos { active.currentCardElapsedNanos = 0 }
        if active.status == .interrupted { active.resume(at: instant, monotonicNanos: nanos) }
        active.monotonicCheckpointNanos = nanos
        try repo.saveSession(active)
        return Self(session: active, nanos: nanos)
    }

    private func assertCurrent(repo: RecallRepository) throws {
        guard session.status == .active, session.currentCardID != nil,
              try repo.session(id: session.id) == session else { throw PracticeError.staleSession }
    }

    public mutating func reveal(repo: RecallRepository) throws {
        try assertCurrent(repo: repo)
        var revealed = session
        revealed.isRevealed = true
        try repo.saveSession(revealed)
        session = revealed
    }

    public mutating func grade(_ grade: Grade, repo: RecallRepository, at instant: Date, nanos: UInt64) throws {
        try assertCurrent(repo: repo)
        guard session.isRevealed else { throw PracticeError.revealRequired }
        guard let id = session.currentCardID, let card = try repo.card(id: id), card.deckID == session.deckID else {
            throw PracticeError.noCurrentCard
        }
        let before = try repo.practiceSchedule(for: card)
        let attemptID = StableID()
        let after = try LeitnerScheduler().apply(grade: grade, to: before, at: instant, attemptID: attemptID)
        let elapsed = foregroundNanos(to: nanos)
        pending = Attempt(id: attemptID, cardID: id, deckID: session.deckID, timestamp: instant,
                          monotonicStartNanos: nanos - min(nanos, elapsed),
                          monotonicEndNanos: nanos, grade: grade, mode: session.mode,
                          beforeSchedule: before, afterSchedule: after, algorithmVersion: 1)
    }

    public mutating func undo() { pending = nil }

    public mutating func next(repo: RecallRepository, nanos: UInt64, at instant: Date? = nil) throws {
        try assertCurrent(repo: repo)
        guard let pending else { throw PracticeError.pendingRequired }
        // Timing for this attempt was frozen at grade selection, not Next.
        var committing = session
        committing.monotonicCheckpointNanos = nanos
        let timestamp = instant ?? pending.timestamp
        let after = try LeitnerScheduler().apply(grade: pending.grade, to: pending.beforeSchedule,
                                                 at: timestamp, attemptID: pending.id)
        let attempt = Attempt(id: pending.id, cardID: pending.cardID, deckID: pending.deckID,
                              timestamp: timestamp, monotonicStartNanos: pending.monotonicStartNanos,
                              monotonicEndNanos: pending.monotonicEndNanos, grade: pending.grade,
                              mode: pending.mode, beforeSchedule: pending.beforeSchedule,
                              afterSchedule: after, algorithmVersion: pending.algorithmVersion)
        session = try repo.recordAttempt(attempt, advancing: committing)
        self.pending = nil
        cardAnchor = nanos
        accumulatedNanos = 0
    }

    public mutating func interrupt(repo: RecallRepository, at instant: Date, nanos: UInt64) throws {
        pending = nil
        guard session.status == .active else { return }
        var interrupted = session
        interrupted.currentCardElapsedNanos = foregroundNanos(to: nanos)
        interrupted.interrupt(at: instant, monotonicNanos: nanos)
        try repo.saveSession(interrupted)
        session = interrupted
    }

    public mutating func abandon(repo: RecallRepository, at instant: Date) throws {
        pending = nil
        guard session.status == .active || session.status == .interrupted else { return }
        var abandoned = session
        abandoned.status = .abandoned
        abandoned.endedAt = instant
        try repo.saveSession(abandoned)
        session = abandoned
    }

    private func foregroundNanos(to nanos: UInt64) -> UInt64 {
        guard nanos >= cardAnchor else { return 0 }
        let sum = accumulatedNanos.addingReportingOverflow(nanos - cardAnchor)
        return sum.overflow ? UInt64.max : sum.partialValue
    }
}

extension RecallRepository {
    /// Missing scheduling data is only a fresh state when no evidence exists.
    /// Queries are sequential repository reads, never nested GRDB access.
    public func practiceSchedule(for card: Card) throws -> ScheduleState {
        if let schedule = try schedule(cardID: card.id) {
            try LeitnerScheduler().validate(schedule)
            return schedule
        }
        guard try evidence(cardID: card.id).isEmpty else { throw PracticeError.missingScheduleEvidence }
        return .initial(at: card.createdAt, algorithmVersion: 1)
    }
}
