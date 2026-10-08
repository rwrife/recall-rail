import Foundation
import XCTest
import RecallRailKit
@testable import RecallStore

final class DatePayloadTests: XCTestCase {
    func testCardSavePreservesReferenceDatePrecision() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let instant = Date(timeIntervalSinceReferenceDate: 812_982_200.0.nextUp)
        let deck = Deck(title: "Precision", createdAt: instant, updatedAt: instant)
        try repo.saveDeck(deck)
        let card = Card(deckID: deck.id, prompt: "Prompt", answer: "Answer",
                        createdAt: instant, updatedAt: instant)
        try repo.saveCard(card)
        XCTAssertEqual(try repo.deck(id: deck.id), deck)
        XCTAssertEqual(try repo.card(id: card.id), card)
    }

    func testDatePayloadPreservesAdjacentFloatingPointValues() throws {
        let base = 812_982_200.0
        for offset in 0..<1024 {
            let date = Date(timeIntervalSinceReferenceDate: base + Double(offset) * base.ulp)
            let payload = try Snapshots.canonicalPayload(date)
            XCTAssertEqual(try JSONDecoder.domain.decode(Date.self, from: Data(payload.utf8)), date)
        }
    }

    func testLegacyEpochDateRemainsReadable() throws {
        let data = Data("1791289400.125".utf8)
        XCTAssertEqual(try JSONDecoder.domain.decode(Date.self, from: data),
                       Date(timeIntervalSince1970: 1_791_289_400.125))
    }
}
