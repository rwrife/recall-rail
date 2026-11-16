import XCTest
import SwiftUI
import RecallRailKit
import RecallStore
@testable import RecallRail

@MainActor
final class OwnershipBoundaryTests: XCTestCase {
    func testCardsExportPropagatesClosedStoreError() throws {
        let queue = try RecallDatabase.openInMemory()
        let library = DeckLibrary(repo: RecallRepository(db: queue))
        try queue.close()
        XCTAssertThrowsError(try library.exportCSV(deckID: StableID()))
    }
    func testOwnershipDeckQueryIncludesArchivedDeckAndPropagatesErrors() throws {
        let queue = try RecallDatabase.openInMemory()
        let repo = RecallRepository(db: queue)
        let now = Date()
        let deck = Deck(title: "Archived export", isArchived: true, createdAt: now, updatedAt: now)
        try repo.saveDeck(deck)
        try repo.saveCard(Card(deckID: deck.id, prompt: "Archived prompt", answer: "Answer", isArchived: true, createdAt: now, updatedAt: now))
        let library = DeckLibrary(repo: repo)
        XCTAssertEqual(try library.ownershipExportDecks(), [deck])
        XCTAssertTrue(try library.exportCSV(deckID: deck.id).contains("Archived prompt"))
        try queue.close()
        XCTAssertThrowsError(try library.ownershipExportDecks())
    }
    func testProductionExportContainsCompleteBackupBytesAndCleansUp() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let now = Date()
        let deck = Deck(title: "Ownership", createdAt: now, updatedAt: now)
        try repo.saveDeck(deck)
        let bytes = try repo.backupJSON()
        let file = try OwnershipExport(data: bytes, type: .json, name: "RecallRail-backup")
        let exported = try OwnershipExport.readBackup(from: file.url)
        XCTAssertEqual(exported, bytes)
        XCTAssertEqual(file.url.lastPathComponent, "RecallRail-backup.json")
        let target = RecallRepository(db: try RecallDatabase.openInMemory())
        try target.restore(target.previewRestore(exported, mode: .replace))
        XCTAssertEqual(try target.allDecks(), [deck])
        try OwnershipExport.removeTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path))
    }
    func testBackupReadRejectsActualOversizedFileAndPropagatesMissingFile() throws {
        let file = try OwnershipExport(data: Data(), type: .json, name: "oversized")
        defer { try? OwnershipExport.removeTemporaryFiles() }
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.truncate(atOffset: UInt64(BackupCodec.maximumBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try OwnershipExport.readBackup(from: file.url))
        XCTAssertThrowsError(try OwnershipExport.readBackup(from: file.url.appendingPathExtension("missing")))
    }
}
