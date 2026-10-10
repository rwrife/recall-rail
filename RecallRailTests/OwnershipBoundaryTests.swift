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
}
