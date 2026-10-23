// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FoxTrainingCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "FoxTrainingCore", targets: ["FoxTrainingCore"]),
               .library(name: "FoxPoseExperimentKit", targets: ["FoxPoseExperimentKit"]),
               .executable(name: "fox-pose-replay", targets: ["FoxPoseReplay"]),
               .executable(name: "fox-video-replay", targets: ["FoxVideoReplay"]),
               .executable(name: "fox-pose-experiment", targets: ["FoxPoseExperiment"])],
    targets: [
        .target(name: "FoxTrainingCore", resources: [.process("Resources")]),
        .executableTarget(name: "FoxPoseReplay", dependencies: ["FoxTrainingCore"]),
        .executableTarget(name: "FoxVideoReplay", dependencies: ["FoxTrainingCore"]),
        .target(name: "FoxPoseExperimentKit", dependencies: ["FoxTrainingCore"]),
        .executableTarget(name: "FoxPoseExperiment", dependencies: ["FoxPoseExperimentKit"]),
        .testTarget(name: "FoxTrainingCoreTests", dependencies: ["FoxTrainingCore"])
    ]
)
