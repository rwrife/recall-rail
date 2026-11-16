import XCTest
import UIKit

@MainActor
final class CompactAccessibilityTests: XCTestCase {
    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id]
        guard button.waitForExistence(timeout: 5) else {
            XCTFail("Missing \(id)")
            return
        }
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<16 {
            let viewport = scroll.frame.intersection(app.windows.firstMatch.frame)
            let top = max(viewport.minY, app.navigationBars.firstMatch.frame.maxY) + 8
            let bottom = viewport.maxY - 8
            guard !viewport.isNull, bottom > top else {
                XCTFail("No visible practice viewport")
                return
            }
            let frame = button.frame
            if button.isHittable && frame.midY > top && frame.midY < bottom {
                XCTAssertGreaterThanOrEqual(frame.height, 44, id)
                XCTAssertGreaterThanOrEqual(frame.width, 44, id)
                button.tap()
                return
            }
            // AX can report offscreen controls as hittable. Use both viewport
            // edges, and keep drags below navigation and above system chrome.
            let down = frame.midY < (top + bottom) / 2
            let startY = top + (bottom - top) * (down ? 0.25 : 0.75)
            let endY = top + (bottom - top) * (down ? 0.75 : 0.25)
            let origin = scroll.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX - scroll.frame.minX, dy: startY - scroll.frame.minY))
            let end = origin.withOffset(CGVector(dx: viewport.midX - scroll.frame.minX, dy: endY - scroll.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Cannot reach \(id) inside content viewport. \(app.debugDescription)")
    }

    func testAXLargeTypePortraitLandscapeRevealGradeUndoAndResume() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        app.buttons["deck-list.create"].tap()
        let title = "Accessibility \(UUID().uuidString)"
        app.textFields["deck-editor.title"].tap()
        app.textFields["deck-editor.title"].typeText(title)
        app.buttons["deck-editor.save"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck-row.' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        for index in 1...2 {
            app.buttons["deck-detail.new-card"].tap()
            let prompt = app.descendants(matching: .any).matching(identifier: "card-editor.prompt").firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 5))
            prompt.tap()
            prompt.typeText("Accessible prompt \(index)")
            let answer = app.descendants(matching: .any).matching(identifier: "card-editor.answer").firstMatch
            answer.tap()
            answer.typeText("Accessible answer \(index)")
            app.buttons["card-editor.save"].tap()
        }
        app.buttons["deck-detail.practice"].tap()
        tap(app, "practice.start")
        tap(app, "practice.reveal")
        tap(app, "practice.interrupt")
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "--rr-size-probe"]
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryAccessibilityXXXL"
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["deck-detail.practice"].tap()
        // Prove the accessibility size actually applied inside the app rather
        // than trusting the launch argument. UIKit surfaces the abbreviated
        // raw category value; assert the exact AX5 category.
        let probe = app.staticTexts["practice.size-category"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        XCTAssertEqual(probe.label, "UICTContentSizeCategoryAccessibilityXXXL", probe.label)
        tap(app, "practice.resume")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "AX5 portrait practice"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Accessible prompt 1")
        // The pre-interruption reveal is durable: the answer must already be
        // visible, and the reveal button must be gone.
        XCTAssertTrue(app.staticTexts["practice.answer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["practice.reveal"].exists)

        let window = app.windows.firstMatch
        func waitForGeometry(portrait: Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let frame = window.frame
                if portrait, frame.height > frame.width { return true }
                if !portrait, frame.width > frame.height { return true }
                usleep(100_000)
            }
            return false
        }
        XCTAssertTrue(waitForGeometry(portrait: true))

        for grade in ["again", "hard", "recalled"] {
            let pendingText = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Pending: \(grade)'")).firstMatch
            tap(app, "practice.grade.\(grade)")
            // AX5 can reflow under the finger while the scroll view settles.
            // Retry a missed tap, but never treat an absent pending state as success.
            if !pendingText.waitForExistence(timeout: 3) { tap(app, "practice.grade.\(grade)") }
            guard pendingText.waitForExistence(timeout: 5) else {
                XCTFail("grade \(grade) produced no pending state: \(app.debugDescription)")
                return
            }
            tap(app, "practice.undo")
            XCTAssertFalse(app.buttons["practice.next"].exists)
        }
        // A revealed card with a pending grade must survive rotation intact.
        tap(app, "practice.grade.hard")
        let pending = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Pending: hard'")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForGeometry(portrait: false))
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "AX5 landscape pending grade"
        landscape.lifetime = .keepAlways
        add(landscape)
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Accessible prompt 1")
        XCTAssertTrue(app.staticTexts["practice.answer"].exists)
        XCTAssertTrue(pending.exists)
        // In landscape, commit the pending grade via Next.
        tap(app, "practice.next")

        // Card 2 in landscape completes the session.
        XCTAssertEqual(app.staticTexts["practice.prompt"].label, "Accessible prompt 2")
        tap(app, "practice.reveal")
        tap(app, "practice.grade.recalled")
        tap(app, "practice.next")
        XCTAssertTrue(app.staticTexts["practice.complete"].waitForExistence(timeout: 5))
    }
}
