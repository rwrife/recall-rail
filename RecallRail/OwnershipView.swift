import SwiftUI
import UIKit
import UniformTypeIdentifiers
import RecallRailKit
import RecallStore

struct OwnershipExport: Identifiable {
    private static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecallRail-export", isDirectory: true)
    let id = UUID()
    let url: URL
    let destinationDirectory: URL

    init(data: Data, type: UTType, name: String) throws {
        guard let suffix = type.preferredFilenameExtension else { throw OwnershipError.invalid("Unknown export file type") }
        let files = FileManager.default
        let documents = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        destinationDirectory = documents.appendingPathComponent("Exports", isDirectory: true)
        try files.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try Self.removeTemporaryFiles()
        try files.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        url = Self.directory.appendingPathComponent(name).appendingPathExtension(suffix)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try Self.removeTemporaryFiles()
            throw error
        }
    }

    static func removeTemporaryFiles() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func readBackup(from url: URL) throws -> Data {
        // App-owned URLs need no additional security scope; opening still
        // throws for a provider URL whose permission was actually denied.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: BackupCodec.maximumBytes + 1) ?? Data()
        guard data.count <= BackupCodec.maximumBytes else { throw OwnershipError.invalid("Backup too large") }
        return data
    }
}

@MainActor
struct OwnershipExporter: UIViewControllerRepresentable {
    enum Outcome { case saved, cancelled }
    let file: OwnershipExport
    let completion: (Result<Outcome, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        picker.directoryURL = file.destinationDirectory
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<Outcome, Error>) -> Void
        init(completion: @escaping (Result<Outcome, Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard urls.count == 1 else {
                completion(.failure(OwnershipError.invalid("Unexpected export destination")))
                return
            }
            completion(.success(.saved))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(.success(.cancelled))
        }
    }
}

struct OwnershipView: View {
    @Bindable var library: DeckLibrary
    @State private var exportDecks: [Deck] = []
    @State private var exportFile: OwnershipExport?
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
    private func export(_ data: Data, type: UTType, name: String) throws {
        exportFile = try OwnershipExport(data: data, type: type, name: name)
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
                    perform { try export(try library.repo.backupJSON(), type: .json, name: "RecallRail-backup") }
                }.accessibilityIdentifier("ownership.backup")
                Button("Export decks CSV") {
                    perform { try export(Data(try library.repo.decksCSV().utf8), type: .commaSeparatedText, name: "RecallRail-decks") }
                }.accessibilityIdentifier("ownership.decks")
                ForEach(exportDecks) { deck in
                    Button("Export cards: \(deck.title)") {
                        perform { try export(Data(try library.exportCSV(deckID: deck.id).utf8), type: .commaSeparatedText, name: "RecallRail-cards") }
                    }.accessibilityIdentifier("ownership.cards.\(deck.id.rawValue)")
                }
                Button("Export attempts CSV") {
                    perform { try export(Data(try library.repo.attemptsCSV().utf8), type: .commaSeparatedText, name: "RecallRail-attempts") }
                }.accessibilityIdentifier("ownership.attempts")
                Text("Export prepares a temporary file. It is removed when the picker closes. Saved copies belong to you and are not erased by deleting app data.")
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
        .task {
            if exportFile == nil { perform { try OwnershipExport.removeTemporaryFiles() } }
            refreshExportDecks()
        }
        .sheet(item: $exportFile, onDismiss: { perform { try OwnershipExport.removeTemporaryFiles() } }) { file in
            OwnershipExporter(file: file) { result in
                switch result {
                case .success(.saved): message = "Export saved."
                case .success(.cancelled): message = "Export cancelled."
                case .failure(let error): message = "Export failed: \(error)"
                }
                exportFile = nil
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            perform {
                imported = try OwnershipExport.readBackup(from: result.get())
                refreshPreview()
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
                    defer { library.reload(); refreshExportDecks(); preview = nil; imported = nil }
                    try OwnershipExport.removeTemporaryFiles()
                    try library.repo.eraseLocalRecords()
                    message = "All local records deleted. Exported copies and device backups remain under your control."
                }
            }
        }
    }
}
