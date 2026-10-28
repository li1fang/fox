// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "FoxSyncCore", platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "FoxSyncCore", targets: ["FoxSyncCore"])],
    targets: [.target(name: "FoxSyncCore"),
        .executableTarget(name: "FoxSyncProbe", dependencies: ["FoxSyncCore"]),
        .testTarget(name: "FoxSyncCoreTests", dependencies: ["FoxSyncCore"])])
