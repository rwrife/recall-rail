import SwiftUI
import RecallRailKit
import RecallStore

struct PracticeView: View {
    @State private var model: PracticeModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var dueOnly = true
    @State private var tags = ""
    @State private var filter = ""
    @State private var spoken = false
    @State private var showHint = false

    init(repo: RecallRepository, deckID: StableID) {
        _model = State(initialValue: PracticeModel(repo: repo, deckID: deckID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                    Text(card.prompt).font(.largeTitle).accessibilityIdentifier("practice.prompt")
                    if let hint = card.hint, !hint.isEmpty {
                        Button(showHint ? "Hide hint" : "Show hint") { showHint.toggle() }
                        if showHint { Text(hint) }
                    }
                    if model.run?.session.isRevealed == true {
                        Text(card.answer).font(.title).accessibilityIdentifier("practice.answer")
                        ForEach(Grade.allCases, id: \.self) { grade in
                            Button(grade.rawValue.capitalized) { model.grade(grade) }
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .accessibilityIdentifier("practice.grade.\(grade.rawValue)")
                        }
                    } else {
                        Button("Reveal answer") { model.reveal() }
                            .accessibilityIdentifier("practice.reveal")
                    }
                    if let pending = model.run?.pending {
                        Text("Pending: \(pending.grade.rawValue). Nothing saved yet.")
                        Button("Undo pending grade") { model.undo() }.accessibilityIdentifier("practice.undo")
                        Button("Next — save attempt") { model.next(); showHint = false }
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
                        Text("\(due.kind.rawValue) · Box \(due.schedule.box) · Due \(due.schedule.dueAt.formatted())")
                    }
                    if let mastery = model.mastery { Text("App evidence: \(mastery.rawValue)") }
                } else {
                    Text("Practice complete").accessibilityIdentifier("practice.complete")
                }
                Text(model.notice).font(.footnote)
                NavigationLink("Raw attempt ledger") {
                    AttemptLedgerView(repo: model.repo, deckID: model.deckID)
                }.accessibilityIdentifier("practice.ledger")
                if let error = model.error { Text("Practice error: \(error)").foregroundStyle(.red) }
            }
            .padding()
            .buttonStyle(.bordered)
        }
        .navigationTitle("Practice")
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.interrupt() }
        }
        .onDisappear { model.interrupt() }
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
