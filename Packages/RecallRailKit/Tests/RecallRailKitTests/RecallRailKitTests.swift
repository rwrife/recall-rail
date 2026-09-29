import XCTest
@testable import RecallRailKit

final class RecallRailKitTests: XCTestCase {
    func testFoundationIdentityIsStable() {
        XCTAssertEqual(RecallRailKit.productName, "Recall Rail")
        XCTAssertEqual(RecallRailKit.foundationVersion, 1)
    }
}
