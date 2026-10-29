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
    func testRecoveryPreservesRecordingSummaryWrittenBeforeManifestPublication() throws {
        let root = try root(), archive = try FreeCaptureArchive(id: UUID(), options: .init(analysis: .none), root: root, synthetic: true)
        let original = Data("{\"schema\":\"fox.lab_recording.v1\",\"encoded_frames\":17,\"dropped_frames\":2,\"first_pts\":{\"value\":\"9001\",\"timescale\":30},\"stop_reason\":\"userStopped\"}".utf8)
        let file = archive.folder.appendingPathComponent("recording.json")
        try original.write(to: file, options: .withoutOverwriting)
        let before = try VisionDiagnosticArchive.asset(file)
        XCTAssertTrue(try FreeCaptureArchive.recover(root: root, currentProcessID: UUID()).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try VisionDiagnosticArchive.asset(file).sha256, before.sha256)
        let library = try FreeCaptureArchive.list(root: root)
        XCTAssertEqual(library.count, 1); XCTAssertFalse(try XCTUnwrap(library.first).videoAvailable)
        XCTAssertNil(library.first?.encodedFrames)
        let recovery = archive.folder.appendingPathComponent("recovery.json"), recoveryBytes = try Data(contentsOf: recovery)
        // A recovery interrupted at the same publication boundary reuses its derived
        // summary without rewriting either the original or the previous recovery.
        try FileManager.default.removeItem(at: archive.folder.appendingPathComponent("manifest.json"))
        XCTAssertTrue(try FreeCaptureArchive.recover(root: root, currentProcessID: UUID()).isEmpty)
        XCTAssertEqual(try Data(contentsOf: recovery), recoveryBytes)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testCrossFieldInvalidManifestsNeverBecomeIntactLibraryEntries() throws {
        for mutation in ["complete_without_asset", "wrong_clock", "unknown_stream"] {
            let root = try root(), archive = try FreeCaptureArchive(id: UUID(), options: .init(analysis: .none), root: root, synthetic: true)
            _ = try archive.seal(video: nil, reason: "cameraUnavailable")
            let file = archive.folder.appendingPathComponent("manifest.json")
            var manifest = try JSONDecoder().decode(LabCaptureManifest.self, from: Data(contentsOf: file))
            if mutation == "complete_without_asset" {
                let i = try XCTUnwrap(manifest.streams.firstIndex { $0.id == "video" })
                manifest.streams[i].state = "complete"; manifest.streams[i].reason = nil
            } else if mutation == "wrong_clock" {
                manifest.streams[0].source.clockID = "foreign-clock"
            } else {
                manifest.files[0].streamID = "missing-stream"
            }
            try JSONEncoder().encode(manifest).write(to: file)
            let before = try Data(contentsOf: file)
            let library = try FreeCaptureArchive.library(root: root)
            XCTAssertTrue(library.packages.isEmpty, mutation)
            XCTAssertEqual(library.issues.count, 1, mutation)
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }
    func testNativeSyntheticVideoPackageCanBeRetainedForIndependentConsumers() async throws {
        let export = ProcessInfo.processInfo.environment["FOX_LAB_NATIVE_EXPORT_ROOT"]
        let base: URL
        if let export { base = URL(fileURLWithPath: export, isDirectory: true) } else { base = try root() }
        let id = UUID(), archive = try FreeCaptureArchive(id: id, options: .init(analysis: .comparison, pumpEnabled: true),
            root: base, synthetic: true, pumpAliases: ["pump-A", "pump-B"])
        let writer = try FreeCaptureVideoWriter(folder: archive.folder)
        var origin: CMTime?, expectedVideoPTS: [Double] = []
        for seq in 0..<6 {
            let sample = try VisionDiagnosticRecorder.syntheticSample(timestamp: Double(6_000_001 + seq * 6000) / 60_000, width: 64, height: 96)
            let host = DispatchTime.now().uptimeNanoseconds, frame = try writer.append(sample)
            if origin == nil { origin = frame.capturePTS }
            try archive.frame(frame, seq: seq, hostNS: host, origin: XCTUnwrap(origin))
            if frame.encoded { expectedVideoPTS.append(try XCTUnwrap(frame.videoTime).seconds) }
            let pts = LabRationalTime(value: String(frame.capturePTS.value), timescale: frame.capturePTS.timescale, epoch: String(frame.capturePTS.epoch))
            let twoD = LabPose2DFrame(captureID: id.uuidString, sourceID: archive.sourceID, seq: seq, pts: pts,
                hostReceivedNS: String(host), width: 64, height: 96, requestRevision: 1, state: "no_observation", reason: nil, people: [], inferenceNS: "0")
            try archive.pose(JSONEncoder().encode(twoD), kind: "pose2d")
            let threeD = Pose3DFrame(context: .init(streamID: archive.sourceID, segmentID: id.uuidString, frameIndex: seq,
                pts: .init(value: frame.capturePTS.value, timescale: frame.capturePTS.timescale, epoch: frame.capturePTS.epoch),
                width: 64, height: 96), requestedRevision: 1, outcome: .unsupported, failure: .init(domain: "fox.synthetic_3d_unavailable", code: 1))
            try archive.pose(JSONEncoder().encode(threeD), kind: "pose3d", issue: "unsupported")
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        for alias in ["pump-A", "pump-B"] {
            try archive.pump(PumpConnectionEvent(captureID: id.uuidString, deviceAlias: alias, connectionSegmentID: "synthetic-\(alias)",
                hostClockID: archive.clockID, hostReceivedNS: DispatchTime.now().uptimeNanoseconds, state: "subscribed_no_data", reason: nil))
            try archive.pump(PumpNotificationEvent(captureID: id.uuidString, deviceAlias: alias, connectionSegmentID: "synthetic-\(alias)",
                hostClockID: archive.clockID, notificationSeq: 0, hostReceivedNS: DispatchTime.now().uptimeNanoseconds,
                bytes: Data([0x53, 0x15, 0x03, 0x03] + Array(repeating: 0, count: 16) + [0x92])))
        }
        let video: FreeCaptureVideoWriter.Summary? = try await withCheckedThrowingContinuation { continuation in
            writer.finish { continuation.resume(with: $0) }
        }
        let saved = try archive.seal(video: XCTUnwrap(video), reason: "userStopped")
        XCTAssertTrue(saved.videoAvailable); XCTAssertGreaterThanOrEqual(saved.encodedFrames ?? 0, 3)
        XCTAssertEqual(try FreeCaptureArchive.list(root: base).filter { $0.id == id }.count, 1)
        let asset = AVURLAsset(url: archive.folder.appendingPathComponent("video.mp4"))
        let audio = try await asset.loadTracks(withMediaType: .audio), tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(audio.isEmpty)
        let track = try XCTUnwrap(tracks.first)
        // Compressed output also contains zero-sample edit/drain/end markers.
        // Compare actual decoded images, retaining exact count and PTS assertions.
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var actualPTS: [[String: Any]] = [], actualSeconds: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample)); XCTAssertTrue(pts.isNumeric)
            actualPTS.append(["value": String(pts.value), "timescale": pts.timescale, "epoch": String(pts.epoch)])
            actualSeconds.append(pts.seconds)
        }
        XCTAssertEqual(reader.status, .completed); XCTAssertEqual(actualSeconds.count, expectedVideoPTS.count)
        for (a, b) in zip(actualSeconds, expectedVideoPTS) { XCTAssertEqual(a, b, accuracy: 1.0 / 60_000) }
        if export != nil {
            let receipt: [String: Any] = ["schema": "fox.lab_native_producer_receipt.v1", "capture_id": id.uuidString,
                "package": archive.folder.path, "data_class": "synthetic", "producer": "actual FreeCaptureVideoWriter + FreeCaptureArchive",
                "declared_code_state": ProcessInfo.processInfo.environment["FOX_LAB_PRODUCER_CODE_STATE"] ?? "uncommitted_test_fixture",
                "video_pts": actualPTS, "manifest_sha256": try VisionDiagnosticArchive.asset(archive.folder.appendingPathComponent("manifest.json")).sha256,
                "video_pts_evidence": "Decoded image buffers; exactly one image/sample and numeric PTS",
                "boundary": "Native production classes with simulated inputs; not camera, BLE, pose accuracy or iOS App-host acceptance"]
            try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys).write(to: base.appendingPathComponent("\(id.uuidString)-producer.json"), options: .withoutOverwriting)
        }
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
        let base = try root(), permanent = base.appendingPathComponent("Permanent"), legacy = base.appendingPathComponent("LegacyDrafts")
        let archive = try FreeCaptureArchive(id: UUID(), options: .init(analysis: .none), root: permanent, synthetic: true)
        _ = try archive.seal(video: nil, reason: "cameraUnavailable")
        let names = try FileManager.default.contentsOfDirectory(atPath: archive.folder.path)
        let before = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: archive.folder.appendingPathComponent($0))) })
        for kind in ["ttl", "quantity", "capacity"] {
            // Keep each policy independent; quantity's ten survivors must not make
            // capacity's result depend on tied, second-resolution creation dates.
            let drafts = legacy.appendingPathComponent(kind)
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
