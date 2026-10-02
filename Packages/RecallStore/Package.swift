// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecallStore",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "RecallStore", targets: ["RecallStore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(path: "../RecallRailKit"),
    ],
    targets: [
        .target(
            name: "RecallStore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "RecallRailKit",
            ]
        ),
        .testTarget(name: "RecallStoreTests", dependencies: ["RecallStore"]),
    ]
)
