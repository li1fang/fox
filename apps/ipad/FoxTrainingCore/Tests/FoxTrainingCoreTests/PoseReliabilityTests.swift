import Foundation
import XCTest
@testable import FoxTrainingCore

final class PoseReliabilityTests: XCTestCase {
    private let angles = [160.0, 160, 160, 160, 160, 140, 120, 110, 100, 90, 80, 55, 55, 55, 55, 55, 55,
                          75, 100, 110, 120, 130, 140, 160, 160, 160, 160, 160, 160]
    private func frame(_ angle: Double, at time: Double, confidence: Double = 1) -> PoseFrame {
        let radians = angle * .pi / 180
        return PoseFrame(timestamp: time, width: 1280, height: 720, people: [BodyPose(points: [
            .leftShoulder: PosePoint(x: 0.45, y: 0.8, confidence: confidence),
            .leftElbow: PosePoint(x: 0.45, y: 0.55, confidence: confidence),
            .leftWrist: PosePoint(x: 0.45 + sin(radians) * 0.22 * 720 / 1280, y: 0.55 + cos(radians) * 0.22, confidence: confidence)
        ])])
    }
    private func feed(to tracker: inout CurlTracker, invalid: Set<Int> = [], start: Double = 0, interval: Double = 0.1) {
        for (i, angle) in angles.enumerated() {
            tracker.process(frame(angle, at: start + Double(i) * interval, confidence: invalid.contains(i) ? 0.1 : 1))
        }
    }
    private func report(_ tracker: CurlTracker) -> VisionTrial {
        VisionTrial(startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 30),
                    device: "fixture", appVersion: "0.3.4", visionRevision: 1, source: .fixture, camera: "front", arm: .left,
                    repetitions: tracker.repetitions, manualAdjustment: 0, referenceCount: 1,
                    metrics: VisionMetrics(processedFrames: tracker.diagnostics.samples.count, interruptions: tracker.interruptions),
                    notes: "", counterDiagnostics: tracker.diagnostics)
    }

    func testShortFlickerKeepsPhaseButNeverAdvancesOnMissingPoints() {
        for missing in [[6], [6, 7], [13], [20], [24]] {
            var tracker = CurlTracker(side: .left)
            feed(to: &tracker, invalid: Set(missing))
            XCTAssertEqual(tracker.repetitions.count, 1, "missing=\(missing)")
            XCTAssertEqual(tracker.interruptions, 0)
            XCTAssertGreaterThan(tracker.diagnostics.recoveries, 0)
            if missing[0] > 7 { XCTAssertGreaterThan(tracker.repetitions.first?.trackingGapSeconds ?? 0, 0) }
            let bad = tracker.diagnostics.samples.filter { $0.reason == .lowConfidence }
            XCTAssertTrue(bad.allSatisfy { $0.smoothedAngle == nil && $0.trackingState == .grace })
        }
    }
    func testDropoutExpiryMultiplePeopleAndPauseNeverBridgeCycle() {
        for failure in ["long", "multiple", "pause"] {
            var tracker = CurlTracker(side: .left)
            for i in 0..<13 { tracker.process(frame(angles[i], at: Double(i) * 0.1)) }
            if failure == "pause" { tracker.interrupt() }
            for i in 13..<18 {
                var value = frame(55, at: Double(i) * 0.1, confidence: failure == "long" ? 0.1 : 1)
                if failure == "multiple" { value.people.append(value.people[0]) }
                tracker.process(value)
            }
            for (i, angle) in [100.0, 120, 140, 160, 160, 160, 160].enumerated() { tracker.process(frame(angle, at: 1.8 + Double(i) * 0.1)) }
            XCTAssertEqual(tracker.repetitions.count, 0)
            feed(to: &tracker, start: 3)
            XCTAssertEqual(tracker.repetitions.count, 1)
        }
    }
    func testTrackingConfidenceHysteresisDoesNotPermitWeakAcquisition() {
        var tracker = CurlTracker(side: .left)
        for i in 0..<10 { tracker.process(frame(160, at: Double(i) * 0.1, confidence: 0.5)) }
        XCTAssertEqual(tracker.snapshot.trackingState, .acquiring)
        tracker.process(frame(160, at: 1))
        for (i, angle) in angles.enumerated() { tracker.process(frame(angle, at: 1.1 + Double(i) * 0.1, confidence: 0.5)) }
        XCTAssertEqual(tracker.repetitions.count, 1)
        XCTAssertEqual(tracker.repetitions[0].minimumConfidence, 0.5)
        XCTAssertNoThrow(try report(tracker).validate())
    }
    func testSingleAngleSpikeIsQuarantinedInsteadOfResetting() {
        var tracker = CurlTracker(side: .left)
        for (i, angle) in angles.enumerated() { tracker.process(frame(i == 10 ? 170 : angle, at: Double(i) * 0.1)) }
        XCTAssertEqual(tracker.repetitions.count, 1)
        XCTAssertTrue(tracker.diagnostics.samples.contains { $0.reason == .angleJump && $0.trackingState == .grace })
    }
    func testUnobservedPeakAndStaticJitterCannotInventRepetition() {
        var tracker = CurlTracker(side: .left)
        feed(to: &tracker, invalid: Set(11...16))
        XCTAssertEqual(tracker.repetitions.count, 0)
        XCTAssertGreaterThan(tracker.diagnostics.resetCounts["dropoutTimeout"] ?? 0, 0)
        var staticTracker = CurlTracker(side: .left)
        for i in 0..<50 { staticTracker.process(frame(i % 2 == 0 ? 160 : 149, at: Double(i) * 0.1)) }
        XCTAssertEqual(staticTracker.repetitions.count, 0)
    }
    func testGraceIsTimeBasedAtDifferentFrameRates() {
        for interval in [0.083, 0.1, 0.125] {
            var tracker = CurlTracker(side: .left)
            feed(to: &tracker, invalid: [6], interval: interval)
            XCTAssertEqual(tracker.repetitions.count, 1, "interval=\(interval)")
        }
    }
    func testShortGapHidingEntirePeakDoesNotCreateAnUnobservedTop() {
        var tracker = CurlTracker(side: .left)
        let sequence = [160.0, 160, 160, 160, 160, 140, 120, 100, 55, 100, 120, 140, 160, 160, 160, 160]
        for (i, angle) in sequence.enumerated() {
            tracker.process(frame(angle, at: Double(i) * 0.1, confidence: i == 8 ? 0.1 : 1))
        }
        XCTAssertEqual(tracker.diagnostics.recoveries, 1)
        XCTAssertEqual(tracker.repetitions.count, 0)
        XCTAssertEqual(tracker.diagnostics.resetCounts["incompleteRange"], 1)
    }
    func testExactReplayConfigurationSnapshotAndInterruptEvents() throws {
        var tracker = CurlTracker(side: .left)
        feed(to: &tracker, invalid: [6, 7])
        tracker.interrupt()
        feed(to: &tracker, start: 3)
        let saved = report(tracker)
        let decoded = try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: LocalTrainingRepository.encoder().encode(saved))
        XCTAssertEqual(decoded.algorithm, "curl_2d_v2")
        let replay = try PoseReplay.replay(decoded)
        XCTAssertEqual(replay.repetitions, tracker.repetitions)
        XCTAssertEqual(replay.diagnostics.resetCounts, tracker.diagnostics.resetCounts)
        let strict = try PoseReplay.replay(decoded, configuration: .legacy)
        XCTAssertEqual(strict.repetitions.count, 1)
        XCTAssertEqual(saved.automaticCount, 2)
        if let directory = ProcessInfo.processInfo.environment["FOX_POSE_EVIDENCE_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("synthetic-reliability-replay.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LocalTrainingRepository.encoder().encode(decoded).write(to: url, options: .atomic)
        }
    }
    func testTraceIsBoundedAndOnlyContainsSelectedJoints() throws {
        var config = PoseCounterConfiguration.standard
        config.tracking.traceCapacity = 5
        var tracker = CurlTracker(side: .left, configuration: config)
        feed(to: &tracker)
        XCTAssertEqual(tracker.diagnostics.samples.count, 5)
        XCTAssertEqual(tracker.diagnostics.droppedSamples, angles.count - 5)
        XCTAssertThrowsError(try PoseReplay.replay(report(tracker)))
        config.tracking.recordsTrace = false
        tracker = CurlTracker(side: .left, configuration: config)
        feed(to: &tracker)
        XCTAssertTrue(tracker.diagnostics.samples.isEmpty)
        XCTAssertThrowsError(try PoseReplay.replay(report(tracker)))
    }
    func testInvalidConfigurationAndWriteFailurePreservePrevious() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pose-config-\(UUID())/settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try PoseConfigurationStore(fileURL: url)
        try store.save(.standard)
        let before = try Data(contentsOf: url)
        var invalid = PoseCounterConfiguration.standard
        invalid.tracking.trackingConfidence = 0.9
        XCTAssertThrowsError(try store.save(invalid))
        invalid = .standard; invalid.curl.peakAngleDegrees = 170
        XCTAssertThrowsError(try invalid.validate())
        invalid = .standard; invalid.tracking.smoothingSeconds = .nan
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertEqual(try Data(contentsOf: url), before)
        let failing = try PoseConfigurationStore(fileURL: url, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        var alternative = PoseCounterConfiguration.standard; alternative.name = "other"
        XCTAssertThrowsError(try failing.save(alternative))
        XCTAssertEqual(failing.configuration, .standard)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testGapCannotSatisfyMinimumMovementTime() {
        var settings = PoseCounterConfiguration.standard
        settings.tracking.minimumMovementSeconds = 0.4
        var visible = CurlTracker(side: .left, configuration: settings)
        feed(to: &visible)
        XCTAssertEqual(visible.repetitions.count, 1)
        var missing = CurlTracker(side: .left, configuration: settings)
        feed(to: &missing, invalid: [8])
        XCTAssertEqual(missing.repetitions.count, 0)
        XCTAssertGreaterThan(missing.diagnostics.resetCounts["movementTooShort"] ?? 0, 0)
    }

    func testCustomProfileActuallyControlsGatesAndReportKeepsSnapshot() throws {
        var settings = PoseCounterConfiguration.standard
        settings.curl.peakAngleDegrees = 100
        settings.curl.returnAngleDegrees = 110
        try settings.validate()
        var original = CurlTracker(side: .left)
        var adjusted = CurlTracker(side: .left, configuration: settings)
        for (i, angle) in angles.enumerated() {
            let value = frame(max(angle, 95), at: Double(i) * 0.1)
            original.process(value); adjusted.process(value)
        }
        XCTAssertEqual(original.repetitions.count, 0)
        XCTAssertEqual(adjusted.repetitions.count, 1)
        let saved = report(adjusted)
        settings.curl.peakAngleDegrees = 90
        XCTAssertEqual(saved.counterDiagnostics?.configuration.curl.peakAngleDegrees, 100)
        XCTAssertEqual(try PoseReplay.replay(saved).repetitions, adjusted.repetitions)
    }
    func testLegacyPolicyIsFrozenIndependentlyOfEditableDefaults() throws {
        var changed = PoseCounterConfiguration.standard
        changed.tracking.acquisitionConfidence = 0.7
        changed.tracking.minimumMovementSeconds = 0.4
        XCTAssertEqual(PoseCounterConfiguration.legacy.tracking.trackingConfidence, 0.55)
        XCTAssertEqual(PoseCounterConfiguration.legacy.tracking.minimumMovementSeconds, 0.20)
        XCTAssertEqual(PoseCounterConfiguration.legacy.tracking.maximumCycleSeconds, 20)
        XCTAssertEqual(PoseCounterConfiguration.legacy.tracking.graceSeconds, 0)
        XCTAssertTrue(PoseCounterConfiguration.legacy.lateralRaise.requiresWrist)
        try PoseCounterConfiguration.legacy.validate()
    }

    func testRestorationAfterGraceDeadlineNeedsFreshAcquisition() {
        var tracker = CurlTracker(side: .left)
        for i in 0..<13 { tracker.process(frame(angles[i], at: Double(i) * 0.1)) }
        tracker.process(frame(55, at: 1.3, confidence: 0.1))
        tracker.process(frame(55, at: 1.55, confidence: 0.5))
        XCTAssertEqual(tracker.snapshot.phase, .waitingForExtension)
        XCTAssertNotEqual(tracker.snapshot.trackingState, .tracking)
        XCTAssertEqual(tracker.diagnostics.resetCounts["dropoutTimeout"], 1)
    }

    func testNumericTraceAtDeviceUptimeReplaysExactlyAndBadTraceIsRejected() throws {
        var tracker = CurlTracker(side: .left)
        feed(to: &tracker, invalid: [13], start: 123456.789)
        let saved = report(tracker)
        let encoded = try LocalTrainingRepository.encoder().encode(saved)
        let reloaded = try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: encoded)
        XCTAssertEqual(try PoseReplay.replay(reloaded).repetitions, tracker.repetitions)
        var bad = reloaded
        let duplicate = bad.counterDiagnostics!.samples[0].joints[0]
        bad.counterDiagnostics?.samples[0].joints.append(duplicate)
        XCTAssertThrowsError(try bad.validate())
        bad = reloaded; bad.counterDiagnostics?.configuration.tracking.trackingConfidence = 2
        XCTAssertThrowsError(try bad.validate())
    }

    func testUnreadableSettingsArePreservedWhenExplicitlyReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pose-corrupt-\(UUID())/settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{broken".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try PoseConfigurationStore(fileURL: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let store = try PoseConfigurationStore.replaceUnreadable(fileURL: url, with: .standard)
        XCTAssertEqual(store.configuration, .standard)
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertTrue(try files.filter { $0 != url }.contains { try Data(contentsOf: $0) == bytes })
    }
}
