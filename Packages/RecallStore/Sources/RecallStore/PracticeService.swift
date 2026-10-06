import Foundation
import RecallRailKit

/// The production practice path. Grades are volatile until explicit Next;
/// reveal/order/cursor are durable. Relaunch conservatively restarts the
/// current card's timer: process uptime cannot prove a reboot did not occur.
public struct PracticeService: Sendable {
    public private(set) var session: StudySession
    public private(set) var pending: Attempt?
    private var cardAnchor: UInt64

    private init(session: StudySession, nanos: UInt64) {
        self.session = session
        self.cardAnchor = nanos
    }

    public static func start(repo: RecallRepository, deckID: StableID, selection: PracticeSelection,
                             mode: PracticeMode, at instant: Date, nanos: UInt64) throws -> Self {
        guard let deck = try repo.deck(id: deckID), !deck.isArchived else { throw PracticeError.emptyQueue }
        if try repo.resumableSession(deckID: deckID) != nil { throw PracticeError.staleSession }
        let cards = try repo.cards(deckID: deckID)
        var schedules: [StableID: ScheduleState] = [:]
        for card in cards { schedules[card.id] = try repo.schedule(cardID: card.id) }
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
        let before = try repo.schedule(cardID: id) ?? .initial(at: card.createdAt, algorithmVersion: 1)
        let attemptID = StableID()
        let after = try LeitnerScheduler().apply(grade: grade, to: before, at: instant, attemptID: attemptID)
        pending = Attempt(id: attemptID, cardID: id, deckID: session.deckID, timestamp: instant,
                          monotonicStartNanos: nanos >= cardAnchor ? cardAnchor : nanos,
                          monotonicEndNanos: nanos, grade: grade, mode: session.mode,
                          beforeSchedule: before, afterSchedule: after, algorithmVersion: 1)
    }

    public mutating func undo() { pending = nil }

    public mutating func next(repo: RecallRepository, nanos: UInt64) throws {
        try assertCurrent(repo: repo)
        guard let pending else { throw PracticeError.pendingRequired }
        // Timing for this attempt was frozen at grade selection, not Next.
        var committing = session
        committing.monotonicCheckpointNanos = nanos
        session = try repo.recordAttempt(pending, advancing: committing)
        self.pending = nil
        cardAnchor = nanos
    }

    public mutating func interrupt(repo: RecallRepository, at instant: Date, nanos: UInt64) throws {
        pending = nil
        guard session.status == .active else { return }
        var interrupted = session
        interrupted.interrupt(at: instant, monotonicNanos: nanos)
        try repo.saveSession(interrupted)
        session = interrupted
    }
}
