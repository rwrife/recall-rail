import SwiftUI
import RecallRailKit
import UniformTypeIdentifiers

/// Pick a CSV file, preview the strict import report, and commit ONLY
/// after the user chooses a mode. The all-or-nothing button is disabled
/// while any error exists; the valid-rows-only button requires an
/// explicit opt-in and still lists every excluded row.
struct CSVImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var library: DeckLibrary
    let deckID: StableID

    @State private var preview: CSVCardImport.Preview?
    @State private var fileName = ""
    @State private var pickerPresented = false
    @State private var decodeError: String?
    @State private var commitError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let preview {
                    previewContent(preview)
                } else {
                    ContentUnavailableView("Import CSV",
                                           systemImage: "tablecells",
                                           description: Text(fileName.isEmpty
                                                ? "Choose a UTF-8 CSV file with prompt and answer columns."
                                                : "\(fileName) could not be read: \(decodeError ?? "unknown error")"))
                }
            }
            .navigationTitle("Import preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("import.cancel")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Choose another file") { pickerPresented = true }
                }
            }
            .fileImporter(isPresented: $pickerPresented,
                          allowedContentTypes: [.commaSeparatedText, .plainText],
                          allowsMultipleSelection: false) { result in
                handlePick(result)
            }
            .onAppear { pickerPresented = true }
        }
        .accessibilityIdentifier("import-sheet")
    }

    @ViewBuilder
    private func previewContent(_ preview: CSVCardImport.Preview) -> some View {
        List {
            Section {
                Text(preview.accessibilitySummary)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("import.summary")
            }
            Section("To add") {
                rows(preview.additions, prefix: "add")
            }
            if !preview.updates.isEmpty {
                Section("To update") {
                    rows(preview.updates, prefix: "update")
                }
            }
            if !preview.unchanged.isEmpty {
                Section("Unchanged (\(preview.unchanged.count))") {
                    Text("Rows identical to stored cards are skipped on commit.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if !preview.warnings.isEmpty {
                Section("Warnings") {
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, issue in
                        Label(issueText(issue), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if !preview.errors.isEmpty {
                Section("Errors") {
                    ForEach(Array(preview.errors.enumerated()), id: \.offset) { _, issue in
                        Label(issueText(issue), systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("import.error")
                    }
                }
            }
            if let commitError {
                Section("Commit failed") {
                    Text(commitError).foregroundStyle(.red)
                        .accessibilityIdentifier("import.commit-error")
                }
            }
            Section {
                Button {
                    commit(preview: preview, validRowsOnly: false)
                } label: {
                    Text("Commit all or nothing")
                        .frame(maxWidth: .infinity)
                }
                .disabled(preview.proposedRows.isEmpty || !preview.canCommitAllOrNothing)
                .accessibilityIdentifier("import.commit-all-or-nothing")

                if !preview.canCommitAllOrNothing, preview.canCommitValidRowsOnly {
                    Button(role: .destructive) {
                        commit(preview: preview, validRowsOnly: true)
                    } label: {
                        Text("Skip error rows and commit valid rows only")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("import.commit-valid-only")
                    .accessibilityHint("Imports only the rows without errors; error rows are listed above and left out.")
                }
            } footer: {
                if !preview.canCommitAllOrNothing {
                    Text("Fix the errors or re-pick a corrected file. Nothing is written until you commit.")
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ proposed: [CSVCardImport.ProposedRow], prefix: String) -> some View {
        ForEach(Array(proposed.enumerated()), id: \.offset) { _, row in
            VStack(alignment: .leading) {
                Text(row.prompt).font(.headline)
                Text("line \(row.lineNumber) · \(row.answer)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("import.row.\(prefix).\(row.lineNumber)")
        }
    }

    private func issueText(_ issue: CSVCardImport.Issue) -> String {
        let location = issue.lineNumber.map { "line \($0)" } ?? "file"
        let field = issue.field.map { " [\($0)]" } ?? ""
        return "\(location)\(field): \(issue.message)"
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else {
            if case let .failure(error) = result { decodeError = String(describing: error) }
            return
        }
        fileName = url.lastPathComponent
        commitError = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            decodeError = "the file could not be read"
            preview = nil
            return
        }
        // Build the preview against the deck's CURRENT stored cards so
        // additions/updates/skips reflect reality at pick time; the store
        // re-validates again at commit.
        preview = CSVCardImport.preview(data: data, existingCards: existingCards())
    }

    private func existingCards() -> [Card] {
        guard let deck = library.decks.first(where: { $0.id == deckID }) else { return [] }
        return library.cards(in: deck, matching: "")
    }

    private func commit(preview: CSVCardImport.Preview, validRowsOnly: Bool) {
        commitError = library.commit(preview: preview, deckID: deckID,
                                     validRowsOnly: validRowsOnly)
        if commitError == nil {
            dismiss()
        }
        // Keep the preview and precise rejection visible on failure.
    }
}
