import SwiftUI
import UIKit
import RecallRailKit
import RecallStore

struct PracticeView: View {
    /// UI-journey seam only: renders the *effective* content size category so
    /// an accessibility-size test proves the setting applied instead of
    /// trusting a launch argument. Production launches never pass the flag.
    private static let sizeProbeEnabled = CommandLine.arguments.contains("--rr-size-probe")
    @State private var model: PracticeModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var dueOnly = true
    @State private var tags = ""
    @State private var filter = ""
    @State private var spoken = false

    init(repo: RecallRepository, deckID: StableID) {
        _model = State(initialValue: PracticeModel(repo: repo, deckID: deckID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if Self.sizeProbeEnabled {
                    Text(UIApplication.shared.preferredContentSizeCategory.rawValue)
                        .accessibilityIdentifier("practice.size-category")
                }
                if model.run == nil {
                    Toggle("Due cards only", isOn: $dueOnly)
                    TextField("Required tags (comma separated)", text: $tags)
                    TextField("Filter prompt, answer or tags", text: $filter)
                    Toggle("Spoken rehearsal", isOn: $spoken)
                    Text("Cards follow your authored order. Reorder cards in the deck before starting.")
                    Button("Start practice") {
                        let required = Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                        model.start(selection: PracticeSelection(dueOnly: dueOnly, tags: required, filter: filter), mode: spoken ? .spoken : .tapReveal)
                    }.accessibilityIdentifier("practice.start")
                    Button("Resume practice") { model.resume() }
                        .accessibilityIdentifier("practice.resume")
                } else if model.run?.session.status == .interrupted {
                    Button("Resume practice") { model.resume() }
                        .accessibilityIdentifier("practice.resume")
                } else if let card = model.card {
                    Text("Card \((model.run?.session.cursor ?? 0) + 1) of \(model.run?.session.cardOrder.count ?? 0)")
                    Text(card.prompt).font(.largeTitle)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("practice.prompt")
                        .accessibilityAction(named: "Reveal answer") { model.reveal() }
                    if let hint = card.hint, !hint.isEmpty {
                        Button(model.workspace.showHint ? "Hide hint" : "Show hint") { model.workspace.showHint.toggle() }
                        if model.workspace.showHint { Text(hint) }
                    }
                    if model.run?.session.isRevealed == true {
                        Text(card.answer).font(.title).accessibilityIdentifier("practice.answer")
                        ForEach(Grade.allCases, id: \.self) { grade in
                            Button(grade.rawValue.capitalized) { model.grade(grade) }
                                .keyboardShortcut(gradeKey(grade), modifiers: [])
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .accessibilityIdentifier("practice.grade.\(grade.rawValue)")
                        }
                    } else {
                        Button("Reveal answer") { model.reveal() }
                            .keyboardShortcut("r", modifiers: [])
                            .accessibilityIdentifier("practice.reveal")
                    }
                    if let pending = model.run?.pending {
                        Text("Pending: \(pending.grade.rawValue). Nothing saved yet.")
                        Button("Undo pending grade") { model.undo() }
                            .keyboardShortcut("z", modifiers: .command)
                            .accessibilityIdentifier("practice.undo")
                        Button("Next — save attempt") { model.next() }
                            .keyboardShortcut(.return, modifiers: [])
                            .accessibilityIdentifier("practice.next")
                    }
                    if model.run?.session.mode == .spoken {
                        Text("Speak aloud, then reveal and self-grade. No recording, transcription, or scoring.")
                        Button("Request microphone permission") { model.requestMicrophone() }
                            .accessibilityIdentifier("practice.microphone")
                    }
                    Button("Interrupt practice") { model.interrupt() }
                        .accessibilityIdentifier("practice.interrupt")
                    if let due = model.due {
                        Text(dueExplanation(due))
                    }
                    if let mastery = model.mastery { Text("App evidence: \(masteryLabel(mastery))") }
                } else if model.run?.session.status == .completed {
                    Text("Practice complete").accessibilityIdentifier("practice.complete")
                } else {
                    Text("Current card unavailable. Abandon this session to start again.")
                }
                if model.hasResumableSession {
                    Button("Abandon session", role: .destructive) { model.abandon() }
                        .accessibilityIdentifier("practice.abandon")
                }
                Text(model.notice).font(.footnote)
                NavigationLink("Raw attempt ledger") {
                    AttemptLedgerView(repo: model.repo, deckID: model.deckID)
                }.accessibilityIdentifier("practice.ledger")
                if let error = model.error { Text("Practice error: \(error)").foregroundStyle(.primary) }
            }
            .padding()
            .buttonStyle(PracticeControlStyle())
        }
        .navigationTitle("Practice")
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.interrupt() }
        }
        .onDisappear { model.interrupt() }
    }

    private func gradeKey(_ grade: Grade) -> KeyEquivalent {
        switch grade {
        case .again: "1"
        case .hard: "2"
        case .recalled: "3"
        }
    }

    private func dueExplanation(_ reason: DueReason) -> String {
        let explanation: String
        switch reason.kind {
        case .neverSeen: explanation = "No recorded attempt yet."
        case .dueElapsed: explanation = "Due because the scheduled instant has arrived."
        case .notDue: explanation = "Not due yet; included by your all-cards selection."
        }
        return "\(explanation) Box \(reason.schedule.box); due \(reason.schedule.dueAt.formatted())."
    }

    private func masteryLabel(_ state: MasteryState) -> String {
        switch state {
        case .unseen: "Unseen"
        case .insufficientEvidence: "Insufficient evidence"
        case .due: "Due"
        case .recentlyRecalled: "Recently recalled"
        case .learning: "Learning"
        }
    }
}

private struct PracticeControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(configuration.role == .destructive
                ? AnyShapeStyle(Color(uiColor: .systemRed))
                : AnyShapeStyle(Color.primary))
            .background(configuration.isPressed ? Color(uiColor: .tertiarySystemFill) : Color(uiColor: .secondarySystemBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct AttemptLedgerView: View {
    let repo: RecallRepository
    let deckID: StableID
    @State private var entries: [Attempt] = []
    @State private var failure: String?

    var body: some View {
        List {
            Text("Self-reported evidence, not guaranteed knowledge. Undo never changes saved history.")
            if let failure { Text("Evidence unavailable: \(failure)") }
            ForEach(entries) { attempt in
                VStack(alignment: .leading) {
                    Text("\(attempt.grade.rawValue) · \(attempt.elapsedMilliseconds) ms · \(attempt.mode.rawValue)")
                    Text(attempt.timestamp.formatted())
                    Text("Box \(attempt.beforeSchedule.box) → \(attempt.afterSchedule.box); due \(attempt.beforeSchedule.dueAt.formatted()) → \(attempt.afterSchedule.dueAt.formatted()); algorithm \(attempt.algorithmVersion)")
                    Text("Consecutive recalls \(attempt.beforeSchedule.consecutiveRecalls) → \(attempt.afterSchedule.consecutiveRecalls); schedule versions \(attempt.beforeSchedule.algorithmVersion) → \(attempt.afterSchedule.algorithmVersion)")
                    Text("Previous attempt \(attempt.beforeSchedule.lastAttemptID?.rawValue ?? "none"); next schedule attempt \(attempt.afterSchedule.lastAttemptID?.rawValue ?? "none")").font(.caption)
                    Text("Card \(attempt.cardID.rawValue) · Attempt \(attempt.id.rawValue)").font(.caption)
                }.accessibilityIdentifier("ledger.attempt.\(attempt.id.rawValue)")
            }
        }
        .navigationTitle("Attempt ledger")
        .task {
            do {
                var loaded: [Attempt] = []
                for card in try repo.cards(deckID: deckID, includeArchived: true) {
                    loaded += try repo.attempts(cardID: card.id)
                }
                entries = loaded.sorted { $0.timestamp < $1.timestamp }
            } catch { entries = []; failure = String(describing: error) }
        }
    }
}
