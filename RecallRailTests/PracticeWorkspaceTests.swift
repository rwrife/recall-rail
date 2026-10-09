import XCTest
import RecallRailKit
import RecallStore
@testable import RecallRail

@MainActor
final class PracticeWorkspaceTests: XCTestCase {
    func testPanePlanSnapshotKeepsFutureCuesOffPresentation() {
        var layout = PracticeWorkspaceLayout()
        XCTAssertEqual(layout.panes, [.init(audience: .privateControls, elements: [.activePromptOrSpeaker, .sessionControls])])
        for presentation in [PracticeWorkspaceLayout.Presentation.simulatedCompanion, .simulatedSpanned] {
            layout.presentation = presentation
            XCTAssertEqual(layout.panes, [
                .init(audience: .privateControls, elements: [.outlineAndDueQueue, .sessionControls]),
                .init(audience: .presentation, elements: [.activePromptOrSpeaker])
            ])
        }
    }

    func testRealModelTransitionsPreserveSessionPendingAndTiming() throws {
        let repo = RecallRepository(db: try RecallDatabase.openInMemory())
        let now = Date()
        let deck = Deck(title: "Workspace", createdAt: now, updatedAt: now)
        try repo.saveDeck(deck)
        for index in 0..<2 {
            try repo.saveCard(Card(deckID: deck.id, prompt: "Prompt \(index)", answer: "Answer \(index)",
                                   sortOrder: index, createdAt: now, updatedAt: now))
        }
        var nanos: UInt64 = 1_000_000_000
        let model = PracticeModel(repo: repo, deckID: deck.id, monotonicNow: { nanos })
        model.start(selection: PracticeSelection(), mode: .tapReveal)
        model.reveal()
        let session = try XCTUnwrap(model.run?.session)
        let card = try XCTUnwrap(model.card)
        nanos = 3_000_000_000
        model.grade(.hard)
        let pending = try XCTUnwrap(model.run?.pending)
        model.workspace.showHint = true
        for presentation in [PracticeWorkspaceLayout.Presentation.simulatedCompanion, .simulatedSpanned, .compact] {
            model.workspace.presentation = presentation
            XCTAssertEqual(model.run?.session, session)
            XCTAssertEqual(model.run?.pending, pending)
            XCTAssertEqual(try repo.session(id: session.id), session)
            XCTAssertEqual(model.card, card)
            XCTAssertTrue(model.workspace.showHint)
        }
        model.undo()
        nanos = 6_000_000_000
        model.grade(.recalled)
        XCTAssertEqual(model.run?.pending?.elapsedMilliseconds, 5_000)
        nanos = 9_000_000_000
        model.next()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.run?.session.cursor, 1)
        XCTAssertFalse(model.workspace.showHint)
        XCTAssertEqual(try repo.attempts(cardID: card.id).first?.elapsedMilliseconds, 5_000)
        nanos = 10_000_000_000
        model.reveal()
        model.workspace.presentation = .simulatedSpanned
        model.grade(.hard)
        XCTAssertEqual(model.run?.pending?.elapsedMilliseconds, 1_000)
        model.interrupt()
        model.workspace.presentation = .compact
        model.resume()
        XCTAssertEqual(model.run?.session.id, session.id)
        XCTAssertEqual(model.run?.session.cursor, 1)
        XCTAssertEqual(model.run?.session.isRevealed, true)
        XCTAssertNil(model.run?.pending)
        // Resume retains measured foreground time (1000 ms) and restarts the
        // uncheckpointed segment: one more second foreground grades at 2000 ms.
        nanos = 11_000_000_000
        model.grade(.hard)
        XCTAssertEqual(model.run?.pending?.elapsedMilliseconds, 2_000)
    }
}
