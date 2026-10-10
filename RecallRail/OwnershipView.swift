import SwiftUI
import UniformTypeIdentifiers
import RecallRailKit
import RecallStore

struct OwnershipDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw OwnershipError.invalid("Unreadable file") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct OwnershipView: View {
    @Bindable var library: DeckLibrary
    @State private var exportDecks: [Deck] = []
    @State private var document: OwnershipDocument?
    @State private var exportType: UTType = .json
    @State private var filename = "RecallRail"
    @State private var exporting = false
    @State private var importing = false
    @State private var imported: Data?
    @State private var mode = RestoreMode.merge
    @State private var preview: RestorePreview?
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var confirmRestore = false

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { message = "Operation failed: \(error)" }
    }
    private func export(_ data: Data, type: UTType, name: String) {
        document = OwnershipDocument(data: data); exportType = type; filename = name; exporting = true
    }
    private func refreshExportDecks() {
        exportDecks = []
        perform { exportDecks = try library.ownershipExportDecks() }
    }
    private func refreshPreview() {
        preview = nil
        guard let imported else { return }
        perform { preview = try library.repo.previewRestore(imported, mode: mode); message = nil }
    }
    var body: some View {
        Form {
            Section("Your files") {
                Button("Export complete JSON backup") {
                    perform { export(try library.repo.backupJSON(), type: .json, name: "RecallRail-backup") }
                }.accessibilityIdentifier("ownership.backup")
                Button("Export decks CSV") {
                    perform { export(Data(try library.repo.decksCSV().utf8), type: .commaSeparatedText, name: "RecallRail-decks") }
                }.accessibilityIdentifier("ownership.decks")
                ForEach(exportDecks) { deck in
                    Button("Export cards: \(deck.title)") {
                        perform { export(Data(try library.exportCSV(deckID: deck.id).utf8), type: .commaSeparatedText, name: "RecallRail-cards") }
                    }.accessibilityIdentifier("ownership.cards.\(deck.id.rawValue)")
                }
                Button("Export attempts CSV") {
                    perform { export(Data(try library.repo.attemptsCSV().utf8), type: .commaSeparatedText, name: "RecallRail-attempts") }
                }.accessibilityIdentifier("ownership.attempts")
                Text("Exports are created only when you choose a file destination. Shared copies belong to you and are not erased by deleting app data.")
            }
            Section("Restore JSON backup") {
                Button("Choose backup file") { preview = nil; imported = nil; message = nil; importing = true }.accessibilityIdentifier("ownership.choose")
                Picker("Restore mode", selection: $mode) {
                    Text("Merge").tag(RestoreMode.merge)
                    Text("Replace all local data").tag(RestoreMode.replace)
                }.onChange(of: mode) { refreshPreview() }
                Text("Merge adds new IDs and rejects any ID with different data. Replace erases current records inside one transaction. Both preserve raw evidence.")
                if let preview {
                    Text("Corrupt evidence preserved unchanged: \(preview.corruptEvidenceCount)")
                    ForEach(preview.counts.keys.sorted(), id: \.self) { table in
                        Text("\(table): file \(preview.counts[table] ?? 0), local \(preview.existingCounts[table] ?? 0)")
                    }
                    Button("Commit restore", role: mode == .replace ? .destructive : nil) { confirmRestore = true }
                        .accessibilityIdentifier("ownership.commit")
                }
            }
            Section("Local privacy") {
                Text("No accounts, cloud, tracking, network calls, recording, or notifications. Spoken rehearsal uses self-grading. The database remains in this app’s container and participates in device backup. Previously exported files and device backups are outside this reset.")
                Button("Delete all my data", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("ownership.delete")
            }
            if let message { Text(message).accessibilityIdentifier("ownership.message") }
        }
        .navigationTitle("Data and privacy")
        .task { refreshExportDecks() }
        .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: filename) { result in
            switch result {
            case .success: message = "Export saved."
            case .failure(let error): message = "Export failed: \(error)"
            }
            document = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            perform {
                let url = try result.get()
                guard url.startAccessingSecurityScopedResource() else { throw OwnershipError.invalid("File permission unavailable") }
                defer { url.stopAccessingSecurityScopedResource() }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= BackupCodec.maximumBytes else { throw OwnershipError.invalid("Backup too large") }
                imported = try Data(contentsOf: url); refreshPreview()
            }
        }
        .confirmationDialog("Restore this preview?", isPresented: $confirmRestore) {
            Button("Restore now", role: mode == .replace ? .destructive : nil) {
                perform {
                    guard let preview else { throw OwnershipError.invalid("Preview missing") }
                    try library.repo.restore(preview)
                    self.preview = nil; imported = nil; library.reload(); refreshExportDecks(); message = "Restore complete."
                }
            }
        } message: { Text("A changed local database invalidates this preview. Replace permanently removes current local records.") }
        .confirmationDialog("Permanently delete all local records?", isPresented: $confirmDelete) {
            Button("Delete everything", role: .destructive) {
                perform {
                    defer { library.reload(); refreshExportDecks(); preview = nil; imported = nil; document = nil }
                    try library.repo.eraseLocalRecords()
                    message = "All local records deleted. Exported copies and device backups remain under your control."
                }
            }
        }
    }
}
