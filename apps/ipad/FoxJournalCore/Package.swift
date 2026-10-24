// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FoxJournalCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "FoxJournalCore", targets: ["FoxJournalCore"])],
    targets: [
        .target(name: "FoxJournalCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "FoxJournalCrashFixture", dependencies: ["FoxJournalCore"]),
        .testTarget(name: "FoxJournalCoreTests", dependencies: ["FoxJournalCore"])
    ]
)
