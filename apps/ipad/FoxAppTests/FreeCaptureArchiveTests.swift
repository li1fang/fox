import XCTest
import AVFoundation
import FoxTrainingCore
@testable import Fox

final class FreeCaptureArchiveTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LabArchive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testUnknownActionSealsCanonicalPackageWithoutZeroCountsOrTrainingFiles() throws {
        let root = try root(), archive = try FreeCaptureArchive(id: UUID(), options: .init(analysis: .none), root: root, synthetic: true)
        let summary = try archive.seal(video: nil, reason: "cameraUnavailable", encodedFrames: 0, droppedFrames: 0)
        XCTAssertFalse(summary.videoAvailable)
        let manifest = try JSONDecoder().decode(LabCaptureManifest.self, from: Data(contentsOf: archive.folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.mode, "free_capture"); XCTAssertNil(manifest.action); XCTAssertNil(manifest.side)
        XCTAssertNil(manifest.utcAnchor)
        XCTAssertEqual(Set(manifest.streams.map { $0.source.clockID }), [manifest.hostClockID])
        XCTAssertTrue(manifest.streams.filter { $0.kind == "pose2d" || $0.kind == "pose3d" }.allSatisfy { $0.state == "not_requested" })
        XCTAssertEqual(Set(manifest.files.map(\.streamID)).count, manifest.files.count)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("training") })
        XCTAssertEqual(try FreeCaptureArchive.list(root: root).map(\.id), [summary.id])
    }
    func testLegacyTTLQuantityAndCapacityPruningNeverTouchesPermanentOriginals() throws {
        let base = try root(), permanent = base.appendingPathComponent("Permanent"), drafts = base.appendingPathComponent("LegacyDrafts")
        let archive = try FreeCaptureArchive(id: UUID(), options: .init(analysis: .none), root: permanent, synthetic: true)
        _ = try archive.seal(video: nil, reason: "cameraUnavailable")
        let names = try FileManager.default.contentsOfDirectory(atPath: archive.folder.path)
        let before = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: archive.folder.appendingPathComponent($0))) })
        for kind in ["ttl", "quantity", "capacity"] {
            for _ in 0..<(kind == "quantity" ? 12 : 1) {
                var c = VisionDiagnosticContext(source: .fixture, device: "synthetic", appVersion: "test", appBuild: "test",
                    camera: "front", exercise: .curl, arm: .left, bodyView: .unknown, screenOrientation: .portrait,
                    configuration: .standard, runtimePolicy: .standard)
                if kind == "ttl" { c.startedAt = Date().addingTimeInterval(-26 * 3600) }
                let folder = try VisionDiagnosticArchive.prepare(c, root: drafts)
                var m = try VisionDiagnosticArchive.seal(context: c, folder: folder, state: "failed", reason: "synthetic", error: nil, video: nil)
                if kind == "ttl" { m.endedAt = Date().addingTimeInterval(-25 * 3600) }
                // Synthetic declared-size metadata exercises the legacy capacity policy without allocating a large file.
                if kind == "capacity" { m.files[0].bytes = 513 * 1024 * 1024 }
                try VisionDiagnosticArchive.encode(m).write(to: folder.appendingPathComponent("manifest.json"))
            }
            try VisionDiagnosticArchive.pruneDrafts(root: drafts)
            let remaining = try VisionDiagnosticArchive.list(root: drafts).count
            if kind == "quantity" { XCTAssertEqual(remaining, 10) }
            else { XCTAssertEqual(remaining, 0) }
            for (name, bytes) in before { XCTAssertEqual(try Data(contentsOf: archive.folder.appendingPathComponent(name)), bytes, kind) }
            XCTAssertEqual(try FreeCaptureArchive.list(root: permanent).count, 1)
        }
    }
    func testRecoverySkipsLiveCaptureAndKeepsOriginalPartialWithoutInventingFrameCount() throws {
        let root = try root(), archive = try FreeCaptureArchive(id: UUID(), options: .init(analysis: .none), root: root, synthetic: true)
        let partial = Data("synthetic-unfinished-video".utf8)
        try partial.write(to: archive.folder.appendingPathComponent("video.partial.mp4"))
        try FreeCaptureArchive.recover(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.folder.appendingPathComponent("manifest.json").path))
        try FreeCaptureArchive.recover(root: root, currentProcessID: UUID())
        XCTAssertEqual(try Data(contentsOf: archive.folder.appendingPathComponent("video.partial.mp4")), partial)
        let saved = try XCTUnwrap(FreeCaptureArchive.list(root: root).first)
        XCTAssertFalse(saved.videoAvailable); XCTAssertNil(saved.encodedFrames); XCTAssertNil(saved.droppedFrames)
        XCTAssertEqual(saved.frameSummary, "帧数未完整统计")
        let manifest = try JSONDecoder().decode(LabCaptureManifest.self, from: Data(contentsOf: archive.folder.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.files.contains { $0.path == "video.partial.mp4" })
        XCTAssertThrowsError(try FreeCaptureArchive(id: archive.id, options: .init(), root: root))
    }
    func testRecoveryKeepsTruncatedRowsOpaqueAndPreservesOriginalBytes() throws {
        let root = try root(), archive = try FreeCaptureArchive(id: UUID(), options: .init(analysis: .none), root: root, synthetic: true)
        let rows = Data("{\"schema\":\"fox.lab_frame.v1\",\"host_received_ns\":\"1\"}\n{\"schema\":".utf8)
        try rows.write(to: archive.folder.appendingPathComponent("frames.jsonl"))
        try FreeCaptureArchive.recover(root: root, currentProcessID: UUID())
        XCTAssertEqual(try Data(contentsOf: archive.folder.appendingPathComponent("frames.jsonl")), rows)
        let manifest = try JSONDecoder().decode(LabCaptureManifest.self, from: Data(contentsOf: archive.folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.streams.first { $0.kind == "camera_frames" }?.recordSchema, "fox.lab_recovered_raw.v1")
        XCTAssertNotEqual(manifest.streams.first { $0.kind == "camera_frames" }?.state, "complete")
    }
    func testMalformedPendingAndSealedFoldersNeverHideOtherSavedOriginals() throws {
        let root = try root(), archive = try FreeCaptureArchive(id: UUID(), options: .init(analysis: .none), root: root, synthetic: true)
        _ = try archive.seal(video: nil, reason: "cameraUnavailable")
        let bad = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        let original = Data("synthetic partial".utf8); try original.write(to: bad.appendingPathComponent("video.partial.mp4"))
        XCTAssertNoThrow(try FreeCaptureArchive.recover(root: root, currentProcessID: UUID()))
        XCTAssertEqual(try FreeCaptureArchive.list(root: root).map(\.id), [archive.id])
        let corrupt = try FreeCaptureArchive(id: UUID(), options: .init(analysis: .none), root: root, synthetic: true)
        _ = try corrupt.seal(video: nil, reason: "cameraUnavailable")
        try Data("corrupt context".utf8).write(to: corrupt.folder.appendingPathComponent("context.json"))
        let library = try? FreeCaptureArchive.list(root: root)
        XCTAssertEqual(library?.map(\.id), [archive.id])
        XCTAssertEqual(try Data(contentsOf: bad.appendingPathComponent("video.partial.mp4")), original)
    }
    func testMissingChangedAndSymlinkedVideoCannotBeListedAsAnIntactSavedPackage() throws {
        let root = try root(), archive = try FreeCaptureArchive(id: UUID(), options: .init(analysis: .none), root: root, synthetic: true)
        let video = archive.folder.appendingPathComponent("video.mp4"), payload = Data("synthetic-integrity-payload-not-a-real-video".utf8)
        try payload.write(to: video)
        // This test checks byte integrity only; actual codec/PTS encoding has separate tests.
        _ = try archive.seal(video: .init(firstPTS: CMTime(value: 1, timescale: 10), lastPTS: CMTime(value: 2, timescale: 10),
                                         width: 64, height: 96, encodedFrames: 2, droppedFrames: 0), reason: "userStopped")
        XCTAssertEqual(try FreeCaptureArchive.list(root: root).count, 1)
        let manifestBytes = try Data(contentsOf: archive.folder.appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at: video)
        XCTAssertTrue(try FreeCaptureArchive.list(root: root).isEmpty)
        var changed = payload; changed[0] ^= 1; try changed.write(to: video)
        XCTAssertTrue(try FreeCaptureArchive.list(root: root).isEmpty)
        try FileManager.default.removeItem(at: video)
        let outside = root.appendingPathComponent("outside-synthetic.bin"); try payload.write(to: outside)
        try FileManager.default.createSymbolicLink(at: video, withDestinationURL: outside)
        let library = try FreeCaptureArchive.library(root: root)
        XCTAssertTrue(library.packages.isEmpty); XCTAssertFalse(library.issues.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), payload)
        XCTAssertEqual(try Data(contentsOf: archive.folder.appendingPathComponent("manifest.json")), manifestBytes)
    }
}
