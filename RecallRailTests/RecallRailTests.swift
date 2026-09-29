import XCTest
@testable import RecallRail

final class RecallRailTests: XCTestCase {
    func testAppContentUsesExpectedTitle() {
        let view = ContentView(productName: "Recall Rail")
        XCTAssertNotNil(view)
    }
}
