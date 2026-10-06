import SwiftUI
import RecallRailKit

/// Authoring sheet for one deck. Edits land on a `DeckDraft` copy; only
/// Save writes, and Cancel/Dismiss never touch stored state. Validation
/// issues appear as an accessibility-visible summary instead of a silent
/// save failure.
struct DeckEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let titleText: String
    @State private var draft: DeckDraft
    @State private var showValidation = false
    let onSave: @MainActor @Sendable (DeckDraft) -> Bool

    init(deck: Deck? = nil, clock: InstantProviding = SystemClock(),
         onSave: @escaping @MainActor @Sendable (DeckDraft) -> Bool) {
        titleText = deck == nil ? "New deck" : "Edit deck"
        _draft = State(initialValue: DeckDraft(deck: deck, at: clock.now()))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Deck") {
                    TextField("Title", text: $draft.title)
                        .accessibilityIdentifier("deck-editor.title")
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .accessibilityIdentifier("deck-editor.notes")
                    TagEditor(tags: $draft.tags)
                }
                if showValidation && !draft.validationIssues.isEmpty {
                    ValidationSummary(issues: draft.validationIssues)
                }
            }
            .navigationTitle(titleText)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("deck-editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if onSave(draft) { dismiss() }
                        else { showValidation = true }
                    }
                    .accessibilityIdentifier("deck-editor.save")
                }
            }
        }
    }
}

/// Authoring sheet for one card.
struct CardEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let titleText: String
    @State private var draft: CardDraft
    @State private var showValidation = false
    let onSave: @MainActor @Sendable (CardDraft) -> Bool

    init(card: Card? = nil, onSave: @escaping @MainActor @Sendable (CardDraft) -> Bool) {
        titleText = card == nil ? "New card" : "Edit card"
        _draft = State(initialValue: CardDraft(card: card))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Prompt & answer") {
                    TextField("Prompt", text: $draft.prompt, axis: .vertical)
                        .accessibilityIdentifier("card-editor.prompt")
                    TextField("Answer", text: $draft.answer, axis: .vertical)
                        .accessibilityIdentifier("card-editor.answer")
                }
                Section("Optional") {
                    TextField("Hint", text: $draft.hint, axis: .vertical)
                        .accessibilityIdentifier("card-editor.hint")
                    TextField("Source", text: $draft.source, axis: .vertical)
                        .accessibilityIdentifier("card-editor.source")
                    TagEditor(tags: $draft.tags)
                }
                if showValidation && !draft.validationIssues.isEmpty {
                    ValidationSummary(issues: draft.validationIssues)
                }
            }
            .navigationTitle(titleText)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("card-editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if onSave(draft) { dismiss() }
                        else { showValidation = true }
                    }
                    .accessibilityIdentifier("card-editor.save")
                }
            }
        }
    }
}

/// Inline editor for the tag list; comma or semicolon separated input.
struct TagEditor: View {
    @Binding var tags: [String]
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tags (comma separated)", text: $text)
                .accessibilityIdentifier("tag-editor.input")
                .onSubmit { commit() }
                .onChange(of: text) { _, _ in commit() }
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(tag: tag) {
                            tags.removeAll { $0 == tag }
                            text = tags.joined(separator: ", ")
                        }
                    }
                }
            }
        }
        .onAppear { text = tags.joined(separator: ", ") }
    }

    private func commit() {
        var seen = Set<String>()
        tags = text
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { tag in
                guard !tag.isEmpty, !seen.contains(tag) else { return false }
                seen.insert(tag)
                return true
            }
    }
}

private struct TagChip: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

/// Read-only summary of validation issues, announced to VoiceOver when
/// Save is pressed while the form is invalid.
struct ValidationSummary: View {
    let issues: [AuthoringValidation.Issue]

    var body: some View {
        Section {
            ForEach(issues) { issue in
                Label(issue.label, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Fix before saving")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Validation issues: \(issues.map(\.label).joined(separator: ". "))")
        .accessibilityIdentifier("validation.summary")
    }
}

/// Simple wrap-to-rows layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x,
                                              y: bounds.minY + position.y),
                                  proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews)
        -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
