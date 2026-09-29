// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecallRailKit",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "RecallRailKit", targets: ["RecallRailKit"]),
    ],
    targets: [
        .target(name: "RecallRailKit"),
        .testTarget(name: "RecallRailKitTests", dependencies: ["RecallRailKit"]),
    ]
)
