// swift-tools-version: 5.9
import PackageDescription
import Foundation

let presentation = ["FreeCaptureController.swift", "FreeCaptureModels.swift", "FreeCaptureAnalysisGate.swift"]
let cases = ["FreeCaptureTests.swift", "FreeCaptureAnalysisTests.swift"]
func excluded(_ folder: String, keeping selected: [String]) -> [String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return try! FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)
        .filter { !selected.contains($0) }.sorted()
}

// Compile the same production sources without the Fox application or camera SDK.
let package = Package(name: "FoxCapturePresentation", platforms: [.macOS(.v13), .iOS(.v16)], targets: [
    .target(name: "FoxCapturePresentation", path: "FoxNative",
        exclude: excluded("FoxNative", keeping: presentation), sources: presentation),
    .testTarget(name: "FoxCapturePresentationTests", dependencies: ["FoxCapturePresentation"], path: "FoxAppTests",
        exclude: excluded("FoxAppTests", keeping: cases), sources: cases)
])
