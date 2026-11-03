// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FoxPumpKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "PumpCore", targets: ["PumpCore"]), .library(name: "FoxPumpApple", targets: ["FoxPumpApple"])],
    targets: [
        .target(name: "PumpCore"),
        .target(name: "FoxPumpApple", dependencies: ["PumpCore"]),
        .testTarget(name: "PumpCoreTests", dependencies: ["PumpCore"], resources: [.copy("Vectors.json")])
    ]
)
