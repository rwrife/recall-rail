import XCTest
import RecallRailKit
import RecallStore
@testable import RecallRail

@MainActor
private final class DeniedPermission: MicrophonePermissionRequesting {
    var requests = 0
    func request(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        requests += 1
        completion(false)
    }
}

@MainActor
final class SpokenPracticeTests: XCTestCase {
    func testDenialOnlyAfterExplicitRequestRetainsRevealUndoAndCommit() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let now = Date()
        let deck = Deck(title: "Spoken", createdAt: now, updatedAt: now)
        let card = Card(deckID: deck.id, prompt: "Say it", answer: "Answer", createdAt: now, updatedAt: now)
        try repo.saveDeck(deck)
        try repo.saveCard(card)
        let permission = DeniedPermission()
        let model = PracticeModel(repo: repo, deckID: deck.id, permission: permission)
        model.start(selection: PracticeSelection(), mode: .spoken)
        XCTAssertNil(model.error, "start: \(model.error ?? "none")")
        XCTAssertEqual(permission.requests, 0)
        model.requestMicrophone()
        XCTAssertEqual(permission.requests, 1)
        XCTAssertTrue(model.notice.contains("denied"))
        model.reveal()
        XCTAssertNil(model.error, "reveal: \(model.error ?? "none")")
        model.grade(.hard)
        XCTAssertNil(model.error, "hard: \(model.error ?? "none")")
        model.undo()
        XCTAssertTrue(try repo.attempts(cardID: card.id).isEmpty)
        model.grade(.recalled)
        model.next()
        XCTAssertNil(model.error)
        XCTAssertEqual(try repo.attempts(cardID: card.id).first?.mode, .spoken)
    }

    func testTapPracticeNeverRequestsMicrophone() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let permission = DeniedPermission()
        let model = PracticeModel(repo: repo, deckID: StableID(), permission: permission)
        model.requestMicrophone()
        XCTAssertEqual(permission.requests, 0)
    }
}
