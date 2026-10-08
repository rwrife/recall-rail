import Foundation
import Observation
import RecallRailKit
import RecallStore
import AVFAudio

@MainActor
protocol MicrophonePermissionRequesting {
    func request(_ completion: @escaping @MainActor @Sendable (Bool) -> Void)
}

struct SystemMicrophonePermission: MicrophonePermissionRequesting {
    func request(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in completion(granted) }
        }
    }
}

@MainActor
@Observable
final class PracticeModel {
    let repo: RecallRepository
    let deckID: StableID
    private let permission: any MicrophonePermissionRequesting
    var run: PracticeService?
    var card: Card?
    var ledger: [Attempt] = []
    var mastery: MasteryState?
    var due: DueReason?
    var error: String?
    var notice = "Grades are pending until Next. Undo cancels only the pending grade."
    var permissionRequests = 0

    init(repo: RecallRepository, deckID: StableID,
         permission: any MicrophonePermissionRequesting = SystemMicrophonePermission()) {
        self.repo = repo
        self.deckID = deckID
        self.permission = permission
    }

    private var nanos: UInt64 { DispatchTime.now().uptimeNanoseconds }

    func perform(_ operation: () throws -> Void) {
        do { try operation(); error = nil; try refresh() }
        catch { self.error = String(describing: error) }
    }

    func start(selection: PracticeSelection, mode: PracticeMode) {
        perform {
            run = try PracticeService.start(repo: repo, deckID: deckID, selection: selection,
                                            mode: mode, at: Date(), nanos: nanos)
        }
    }

    func resume() {
        perform {
            if let session = try repo.resumableSession(deckID: deckID) {
                run = try PracticeService.resume(repo: repo, session: session, at: Date(), nanos: nanos)
                notice = "Resumed. Any uncommitted grade was canceled. Uncheckpointed timing restarted; background time is excluded."
            }
        }
    }

    func reveal() { perform { try run?.reveal(repo: repo) } }
    func grade(_ grade: Grade) { perform { try run?.grade(grade, repo: repo, at: Date(), nanos: nanos) } }
    func undo() { run?.undo() }
    func next() { perform { try run?.next(repo: repo, nanos: nanos, at: Date()) } }
    func interrupt() {
        perform { try run?.interrupt(repo: repo, at: Date(), nanos: nanos) }
        notice = "Pending grade canceled. Measured foreground time saved; background time is excluded."
    }

    func abandon() {
        perform {
            if var current = run {
                try current.abandon(repo: repo, at: Date())
                run = nil
            } else if let session = try repo.resumableSession(deckID: deckID) {
                var active = try PracticeService.resume(repo: repo, session: session, at: Date(), nanos: nanos)
                try active.abandon(repo: repo, at: Date())
                run = nil
            }
            card = nil
            due = nil
            mastery = nil
            ledger = []
            notice = "Practice session abandoned. You can start a fresh session."
        }
    }

    var hasResumableSession: Bool {
        (try? repo.resumableSession(deckID: deckID)) != nil
    }

    /// Only this explicit action requests microphone access. No capture or
    /// audio session is started, even on grant; spoken practice is self-grade.
    func requestMicrophone() {
        guard run?.session.mode == .spoken else { return }
        permissionRequests += 1
        permission.request { [weak self] granted in
            self?.notice = granted
                ? "Permission granted. Speak aloud and self-grade. No audio is recorded or retained."
                : "Microphone denied. Reveal and all self-grade controls remain available."
        }
    }

    func refresh() throws {
        guard let id = run?.session.currentCardID else { card = nil; return }
        guard let stored = try repo.card(id: id) else { throw PracticeError.noCurrentCard }
        card = stored
        // No guessed schedule/mastery on read failure: clear stale labels.
        due = nil
        mastery = nil
        ledger = []
        let schedule = try repo.practiceSchedule(for: stored)
        ledger = try repo.attempts(cardID: id)
        let scheduler = LeitnerScheduler()
        try scheduler.validate(schedule)
        due = scheduler.dueReason(for: schedule, at: Date())
        mastery = MasteryDeriver(scheduler: scheduler).derive(evidence: try repo.evidence(cardID: id), currentSchedule: schedule, at: Date())
    }
}
