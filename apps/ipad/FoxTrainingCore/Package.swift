// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FoxTrainingCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "FoxVision3D", targets: ["FoxVision3D"]),
               .executable(name: "fox-vision3d-replay", targets: ["FoxVision3DReplay"]),.library(name: "FoxTrainingCore", targets: ["FoxTrainingCore"]),
               .library(name: "FoxTestSupport", targets: ["FoxTestSupport"]),
               .library(name: "FoxPoseExperimentKit", targets: ["FoxPoseExperimentKit"]),
               .executable(name: "fox-pose-replay", targets: ["FoxPoseReplay"]),
               .executable(name: "fox-video-replay", targets: ["FoxVideoReplay"]),
               .executable(name: "fox-pose-experiment", targets: ["FoxPoseExperiment"])],
    targets: [
        .target(name: "FoxVision3D", dependencies: ["FoxTrainingCore"]),
        .executableTarget(name: "FoxVision3DReplay", dependencies: ["FoxVision3D", "FoxTrainingCore"]),
        .target(name: "FoxTrainingCore", resources: [.process("Resources")]),
        .executableTarget(name: "FoxPoseReplay", dependencies: ["FoxTrainingCore"]),
        .executableTarget(name: "FoxVideoReplay", dependencies: ["FoxTrainingCore"]),
        .target(name: "FoxPoseExperimentKit", dependencies: ["FoxTrainingCore"]),
        .executableTarget(name: "FoxPoseExperiment", dependencies: ["FoxPoseExperimentKit"]),
        .target(name: "FoxTestSupport", resources: [.process("Resources")]),
        .testTarget(name: "FoxTrainingCoreTests", dependencies: ["FoxTrainingCore", "FoxTestSupport", "FoxVision3D"])
    ]
)
