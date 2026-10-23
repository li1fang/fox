import Foundation
import XCTest
import CryptoKit
@testable import FoxTrainingCore

final class PoseLiveR2Tests: XCTestCase {
    private let angles = [138.0, 138, 138, 138, 138, 120, 110, 100, 80, 55, 50, 50, 50,
                          50, 50, 50, 50, 50, 50, 60, 80, 100, 110, 120, 138, 145, 150, 150, 150]
    private func frame(_ angle: Double, _ time: Double) -> PoseFrame {
        let a = angle * .pi / 180
        return PoseFrame(timestamp: time, width: 1280, height: 720, people: [BodyPose(points: [
            .leftShoulder: PosePoint(x: 0.45, y: 0.8), .leftElbow: PosePoint(x: 0.45, y: 0.55),
            .leftWrist: PosePoint(x: 0.45 + sin(a) * 0.22 * 720 / 1280, y: 0.55 + cos(a) * 0.22)
        ])])
    }

    func testFirstCycleAtObservedPartialExtension() {
        var tracker = CurlTracker(side: .left, runtimePolicy: .standard)
        for (i, angle) in angles.enumerated() { tracker.process(frame(angle, Double(i) * 0.1)) }
        XCTAssertEqual(tracker.repetitions.count, 1)
        XCTAssertLessThan(tracker.repetitions.first?.startedAtSeconds ?? 99, 1)
    }

    func testSyntheticReportWireAndPhaseStayIndependentOfCounts() throws {
        for gap in [false, true] {
            var tracker = CurlTracker(side: .left, runtimePolicy: .standard)
            var countOnlyPolicy = PoseRuntimePolicy.standard
            countOnlyPolicy.eccentricPolicy = nil
            var countOnly = CurlTracker(side: .left, runtimePolicy: countOnlyPolicy)
            for (i, angle) in angles.enumerated() {
                var f = frame(angle, Double(i) * 0.1)
                if gap && (14...17).contains(i) { f.people[0].points[.leftWrist] = nil }
                tracker.process(f); countOnly.process(f)
            }
            XCTAssertEqual(tracker.repetitions.count, 1)
            XCTAssertEqual(tracker.repetitions.map(\.completedAtSeconds), countOnly.repetitions.map(\.completedAtSeconds))
            XCTAssertEqual(tracker.repetitions.first?.eccentric?.status, gap ? .trackingGap : .measured)
            let trial = VisionTrial(startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 10),
                device: "synthetic", appVersion: "R2", visionRevision: 1, source: .fixture, camera: "front", arm: .left,
                repetitions: tracker.repetitions, manualAdjustment: 0, referenceCount: 1, metrics: .init(), notes: "Synthetic schema fixture",
                counterDiagnostics: tracker.diagnostics)
            try trial.validate()
            let data = try LocalTrainingRepository.encoder().encode(trial)
            let decoded = try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: data)
            XCTAssertEqual(try PoseReplay.replay(decoded).repetitions, trial.repetitions)
            if let output = ProcessInfo.processInfo.environment["FOX_R2_EVIDENCE_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("synthetic-\(gap ? "gap" : "measured").json"), options: .atomic)
            }
        }
    }

    func testWristOnlyGapAfterObservedPeakCanRecover() {
        var tracker = CurlTracker(side: .left, runtimePolicy: .standard)
        for (i, angle) in angles.enumerated() {
            var f = frame(i < 5 ? 160 : angle, Double(i) * 0.1)
            if (14...17).contains(i) { f.people[0].points[.leftWrist]?.confidence = 0.3 }
            tracker.process(f)
        }
        XCTAssertEqual(tracker.repetitions.count, 1)
        XCTAssertEqual(tracker.repetitions.first?.trackingGapSeconds ?? 0, 0.5, accuracy: 0.000001)
        XCTAssertTrue(tracker.diagnostics.samples.filter { $0.reason == .lowConfidence }.allSatisfy { $0.smoothedAngle == nil })
    }

    func testExtendedGapNeverBridgesUnsafeCases() {
        for failure in ["long", "elbow", "shoulder", "noPerson", "mixedGap", "multiple", "ambiguous", "hiddenPeak", "pause", "frameGap"] {
            var tracker = CurlTracker(side: .left, runtimePolicy: .standard)
            for (i, angle) in angles.enumerated() {
                if failure == "frameGap" && (14...17).contains(i) { continue }
                var f = frame(i < 5 ? 160 : angle, Double(i) * 0.1)
                if failure == "hiddenPeak" && (9...20).contains(i) { f.people[0].points[.leftWrist] = nil }
                if failure == "pause" && i == 14 { tracker.interrupt() }
                if (14...(failure == "long" ? 20 : 17)).contains(i) {
                    f.people[0].points[.leftWrist] = nil
                    if failure == "elbow" { f.people[0].points[.leftElbow]?.x += 0.1 }
                    if failure == "shoulder" { f.people[0].points[.leftShoulder]?.x += 0.1 }
                    if failure == "multiple" { f.people.append(f.people[0]) }
                    if failure == "noPerson" { f.people = [] }
                    if failure == "mixedGap" && i == 14 { f.people = [] }
                }
                tracker.process(f, selection: failure == "ambiguous" && (14...17).contains(i) ? PoseSubjectSelection(state: .ambiguous) : nil)
            }
            XCTAssertEqual(tracker.repetitions.count, 0, failure)
        }
    }

    func testPrivateLiveReportsCandidateAndFrozenReplay() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".tmp/live-trial-review-20261023/ipad-records/vision-trials.v1.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Private live archive absent; not live accuracy acceptance")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                       "829d409caddb1b5bbb3b14864a8e589e46f1721d40b54123be57a1cacfdf5a7f")
        let trials = try VisionTrialRepository(fileURL: url).trials
        for trial in trials where trial.counterDiagnostics?.samples.isEmpty == false {
            XCTAssertEqual(try PoseReplay.replay(trial).repetitions, trial.repetitions, "Frozen \(trial.id)")
            var r1 = PoseRuntimePolicy.standard
            r1.curlRecovery = nil; r1.eccentricPolicy = nil
            let before = try PoseReplay.replay(trial, runtimePolicy: r1)
            let after = try PoseReplay.replay(trial, runtimePolicy: .standard)
            print("R2_HISTORY \(trial.id) frozen=\(trial.automaticCount) priorRuntime=\(before.repetitions.count) candidate=\(after.repetitions.count)")
            if trial.id.uuidString.hasPrefix("C70D2DDF") {
                XCTAssertEqual(after.repetitions.count, 0, "Unsupported frontal curl must not acquire invented repetitions")
            }
        }
        let cases = [("BF5C6F4F-C1CA-47EA-A790-E733E227C672", 7),
                     ("1ACF2BA4-E5D1-46A0-A541-CCBCAD50066E", 6),
                     ("C6D5DA27-4979-4F46-8A8A-1E48ED2971B8", 5)]
        for (id, count) in cases {
            let trial = try XCTUnwrap(trials.first { $0.id.uuidString == id })
            let d = try XCTUnwrap(trial.counterDiagnostics)
            var tracker = CurlTracker(side: trial.arm, exercise: trial.resolvedExercise, configuration: d.configuration, runtimePolicy: .standard)
            for s in d.samples {
                if s.kind == "interrupt" { tracker.interrupt() }
                else { tracker.process(s.frame, originalPeopleCount: s.originalPeopleCount,
                    selection: s.subjectState.map { PoseSubjectSelection(state: $0, index: s.selectedSubjectIndex) }) }
            }
            XCTAssertEqual(tracker.repetitions.count, count, id)
            let candidate = VisionTrial(startedAt: trial.startedAt, endedAt: trial.endedAt, device: trial.device,
                appVersion: "R2-replay", visionRevision: trial.visionRevision, source: .fixture, camera: trial.camera,
                arm: trial.arm, repetitions: tracker.repetitions, manualAdjustment: 0, referenceCount: trial.referenceCount,
                metrics: trial.metrics, notes: "Counterfactual replay, not a new camera trial", exercise: trial.resolvedExercise,
                counterDiagnostics: tracker.diagnostics)
            try candidate.validate()
            let encoded = try LocalTrainingRepository.encoder().encode(candidate)
            let decoded = try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: encoded)
            XCTAssertEqual(try PoseReplay.replay(decoded).repetitions, candidate.repetitions)
            if let output = ProcessInfo.processInfo.environment["FOX_R2_EVIDENCE_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoded.write(to: directory.appendingPathComponent("candidate-\(id).json"), options: .atomic)
            }
            let preserved = trial.resolvedExercise == .curl ? Array(tracker.repetitions.dropFirst()) : tracker.repetitions
            XCTAssertEqual(preserved.map(\.completedAtSeconds), trial.repetitions.map(\.completedAtSeconds), id)
            if trial.resolvedExercise == .lateralRaise {
                let legacyFields = preserved.map { rep -> CurlRepetition in var value = rep; value.eccentric = nil; return value }
                XCTAssertEqual(legacyFields, trial.repetitions)
                XCTAssertEqual(tracker.diagnostics.resetCounts, d.resetCounts)
                XCTAssertEqual(tracker.diagnostics.samples.count, d.samples.count)
                for (candidate, original) in zip(tracker.diagnostics.samples, d.samples) {
                    XCTAssertEqual(candidate.automaticCount, original.automaticCount)
                    XCTAssertEqual(candidate.phase, original.phase)
                    XCTAssertEqual(candidate.trackingState, original.trackingState)
                }
            }
        }
    }

    func testInvalidNewPolicyAndUnavailablePhaseCannotMasqueradeAsMeasured() throws {
        var policy = PoseRuntimePolicy.standard
        policy.curlRecovery?.wristOnlyGraceSeconds = 10
        XCTAssertThrowsError(try policy.validate())
        policy = .standard; policy.curlRecovery?.initialEndpointToleranceDegrees = 15
        XCTAssertThrowsError(try PoseSessionSettings(configuration: .standard, runtimePolicy: policy).validate())
        policy = .standard; policy.eccentricPolicy?.confirmationSeconds = .nan
        XCTAssertThrowsError(try policy.validate())
        var result = PoseEccentricMeasurement(status: .trackingGap)
        result.durationSeconds = 1
        XCTAssertThrowsError(try result.validate(start: 0, end: 5, gap: 0.5))
        result = PoseEccentricMeasurement(status: .measured, startedAtSeconds: 1, detectedAtSeconds: 1.5, endedAtSeconds: 3, durationSeconds: 2, onsetUncertaintySeconds: 0.2)
        XCTAssertThrowsError(try result.validate(start: 0, end: 5, gap: 0.5))
        XCTAssertNoThrow(try result.validate(start: 0, end: 5, gap: 0))
    }
}
