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
    func testProductionDocumentContainsCompleteBackupBytes() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let now = Date()
        let deck = Deck(title: "Ownership", createdAt: now, updatedAt: now)
        try repo.saveDeck(deck)
        let bytes = try repo.backupJSON()
        let document = OwnershipDocument(data: bytes)
        XCTAssertEqual(document.data, bytes)
        let target = RecallRepository(db: try RecallDatabase.openInMemory())
        try target.restore(target.previewRestore(document.data, mode: .replace))
        XCTAssertEqual(try target.allDecks(), [deck])
    }
    func testAppOwnedBackupReadIsBoundedAndPropagatesMissingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("backup bytes".utf8)
        try bytes.write(to: url)
        XCTAssertEqual(try OwnershipDocument(backupURL: url).data, bytes)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(BackupCodec.maximumBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try OwnershipDocument(backupURL: url))
        XCTAssertThrowsError(try OwnershipDocument(backupURL: url.appendingPathExtension("missing")))
    }
}
