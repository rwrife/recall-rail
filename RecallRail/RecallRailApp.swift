import SwiftUI
import RecallRailKit

@main
struct RecallRailApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(productName: RecallRailKit.productName)
        }
    }
}
