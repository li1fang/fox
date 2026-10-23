import Foundation
import XCTest
@testable import FoxTrainingCore

final class VisionTrialTests: XCTestCase {
    private func trial() -> VisionTrial {
        let now = Date(timeIntervalSince1970: 1700000000)
        return VisionTrial(startedAt: now, endedAt: now.addingTimeInterval(10), device: "simulator", appVersion: "0.3",
            visionRevision: 1, source: .fixture, camera: "front", arm: .left,
            repetitions: [CurlRepetition(liftSeconds: 1, holdSeconds: 0.5, lowerSeconds: 2, completedAtSeconds: 4, minimumConfidence: 0.8)],
            manualAdjustment: 1, referenceCount: 2, metrics: VisionMetrics(), notes: "测试")
    }

    func testCorrectionPreservesOriginalCountAndFixtureProvenance() throws {
        let report = trial()
        try report.validate()
        let json = try LocalTrainingRepository.encoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["confirmedCount"] as? Int, 2)
        XCTAssertNil(object["frames"])
        XCTAssertNil(object["points"])
        let reloaded = try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: json)
        XCTAssertEqual(reloaded.automaticCount, 1)
        XCTAssertEqual(reloaded.confirmedCount, 2)
        XCTAssertEqual(reloaded.referenceCount, 2)
        XCTAssertEqual(reloaded.source, .fixture)
        XCTAssertEqual(reloaded.repetitions, report.repetitions)
    }

    func testReportReloadAndDuplicateSaveProtection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fox-vision-\(UUID())/trials.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = try VisionTrialRepository(fileURL: url)
        try repository.append(trial())
        let loaded = try VisionTrialRepository(fileURL: url)
        XCTAssertEqual(loaded.trials, repository.trials)
        XCTAssertThrowsError(try repository.append(repository.trials[0]))
    }

    func testInvalidMetricsAndCountsRejected() {
        var report = trial()
        report.manualAdjustment = -2
        XCTAssertThrowsError(try report.validate())
        report = trial(); report.automaticCount = 2
        XCTAssertThrowsError(try report.validate())
        report = trial(); report.metrics.latencyP95Ms = .nan
        XCTAssertThrowsError(try report.validate())
    }

    func testWriteFailureAndCorruptReadPreserveEvidence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fox-vision-\(UUID())/trials.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = try VisionTrialRepository(fileURL: url, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try repository.append(trial()))
        XCTAssertTrue(repository.trials.isEmpty)
        let bad = Data("{bad".utf8)
        try bad.write(to: url)
        XCTAssertThrowsError(try VisionTrialRepository(fileURL: url))
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }

    func testExerciseAlgorithmBindingAndLegacyCurlCompatibility() throws {
        var report = trial()
        report.exercise = .lateralRaise
        XCTAssertThrowsError(try report.validate())
        report.algorithm = VisionExercise.lateralRaise.algorithm
        try report.validate()
        let encoded = try LocalTrainingRepository.encoder().encode(report)
        let reloaded = try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: encoded)
        XCTAssertEqual(reloaded.resolvedExercise, .lateralRaise)
        report.exercise = nil
        XCTAssertThrowsError(try report.validate())
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalTrainingRepository.encoder().encode(trial())) as? [String: Any])
        legacy.removeValue(forKey: "exercise")
        let old = try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: JSONSerialization.data(withJSONObject: legacy))
        try old.validate()
        XCTAssertNil(old.exercise)
        XCTAssertEqual(old.resolvedExercise, .curl)
        XCTAssertEqual(old.automaticCount, 1)
    }

    func testMixedExerciseArchiveReloadKeepsSeparateIdentityAndCounts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fox-two-exercises-\(UUID())/trials.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = try VisionTrialRepository(fileURL: url)
        var curl = trial()
        curl.exercise = nil
        var lateral = trial()
        lateral.exercise = .lateralRaise; lateral.algorithm = VisionExercise.lateralRaise.algorithm
        lateral.captureContext = VisionCaptureContext(declaredBodyView: .front)
        try repository.append(curl); try repository.append(lateral)
        let reloaded = try VisionTrialRepository(fileURL: url)
        XCTAssertEqual(reloaded.trials, [curl, lateral])
        XCTAssertEqual(reloaded.trials.map(\.resolvedExercise), [.curl, .lateralRaise])
        XCTAssertNil(reloaded.trials[0].exercise)
        XCTAssertEqual(reloaded.trials[1].captureContext?.bodyViewSource, "user")
    }
}
