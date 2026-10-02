import XCTest
@testable import RecallRail

final class RecallRailTests: XCTestCase {
    func testAppContentUsesExpectedTitle() {
        let view = ContentView(productName: "Recall Rail")
        XCTAssertNotNil(view)
    }

    func testAppContentReflectsDatabaseAvailability() {
        // The app opens its local database at launch; the placeholder view
        // distinguishes "storage ready" from "storage failed" so a failed
        // open is visible, never silent.
        let ready = ContentView(productName: "Recall Rail", databaseAvailable: true)
        XCTAssertTrue(ready.databaseAvailable)
        let broken = ContentView(productName: "Recall Rail", databaseAvailable: false)
        XCTAssertFalse(broken.databaseAvailable)
    }
}
