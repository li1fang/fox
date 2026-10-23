import CryptoKit
import Foundation
import XCTest
@testable import FoxTrainingCore

final class PoseEccentricVideoTests: XCTestCase {
    private struct Labels: Decodable { var labels: [Label] }
    private struct Label: Decodable {
        var name: String
        var trialID: String?
        var candidateRepIndex: Int
        var videoSHA256: String
        var trialOriginVideoSeconds: Double?
        var segmentStartSeconds: Double?
        var segmentEndSeconds: Double?
        var descentStartVideoSeconds: [Double]
        var returnEndpointVideoSeconds: [Double]
        var expectedStatus: PoseEccentricStatus
    }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func labels() throws -> [Label] {
        try JSONDecoder().decode(Labels.self, from: Data(contentsOf: root.appendingPathComponent(
            "docs/fitness/experiments/eccentric-r2-labels-20261023.json"))).labels
    }
    private func assertLabel(_ label: Label, _ result: PoseEccentricMeasurement?, origin: Double) throws {
        let result = try XCTUnwrap(result, label.name)
        XCTAssertEqual(result.status, label.expectedStatus, label.name)
        if label.expectedStatus == .measured {
            let start = try XCTUnwrap(result.startedAtSeconds) + origin
            let uncertainty = try XCTUnwrap(result.onsetUncertaintySeconds)
            let earliest = start - uncertainty
            let end = try XCTUnwrap(result.endedAtSeconds) + origin
            XCTAssertLessThanOrEqual(uncertainty, 0.8, label.name)
            XCTAssertTrue(start >= label.descentStartVideoSeconds[0] && earliest <= label.descentStartVideoSeconds[1],
                "\(label.name) onset [\(earliest), \(start)] misses manual interval")
            XCTAssertTrue((label.returnEndpointVideoSeconds[0]...label.returnEndpointVideoSeconds[1]).contains(end), "\(label.name) end \(end)")
            print("R2_PHASE \(label.name) onset=[\(earliest),\(start)] end=\(end) duration=[\(result.durationSeconds!),\(result.durationSeconds! + uncertainty)] detectionDelayFromEarliest=\(result.detectedAtSeconds! - result.startedAtSeconds! + uncertainty)")
        } else { XCTAssertNil(result.durationSeconds) }
    }
    func testPrivateLiveVideoLabelsAndGapAbstention() throws {
        let archive = root.appendingPathComponent(".tmp/live-trial-review-20261023/ipad-records/vision-trials.v1.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: archive.path), "Private archive absent; timing is NOT verified")
        let trials = try VisionTrialRepository(fileURL: archive).trials
        let folders = ["BF5C6F4F-C1CA-47EA-A790-E733E227C672": "EE2A6E61-3241-4272-BE33-9DBD298D51F8",
                       "1ACF2BA4-E5D1-46A0-A541-CCBCAD50066E": "D7C81796-A099-45EA-AE1C-B68DEF887315"]
        for label in try labels() where label.trialID != nil {
            let id = label.trialID!, folder = try XCTUnwrap(folders[id])
            let video = root.appendingPathComponent(".data/vision-diagnostics/inbox/\(folder)/video.mp4")
            try XCTSkipUnless(FileManager.default.fileExists(atPath: video.path), "Private labeled video absent")
            XCTAssertEqual(sha(try Data(contentsOf: video)), label.videoSHA256)
            let trial = try XCTUnwrap(trials.first { $0.id.uuidString == id })
            let tracker = try PoseReplay.replay(trial, runtimePolicy: .standard)
            XCTAssertTrue(tracker.repetitions.indices.contains(label.candidateRepIndex))
            try assertLabel(label, tracker.repetitions[label.candidateRepIndex].eccentric, origin: label.trialOriginVideoSeconds!)
        }
    }
    func testPrivateA03BothArmsAgainstVideoIntervals() throws {
        let url = root.appendingPathComponent(".tmp/pose-comparison-20261017/ipad-r1/vision.jsonl")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Private M4 observations absent; timing is NOT verified")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(sha(bytes), "84f2651a2f8b5fc1fd71c6a98e5b43f66ac8afb70ae3f8d12e6db2948af7f7f7")
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
        let label = try XCTUnwrap(labels().first { $0.trialID == nil })
        let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: String]
        XCTAssertEqual(header["videoSHA256"], label.videoSHA256)
        let rows = try lines.dropFirst().map { try JSONDecoder().decode(PoseVideoRow.self, from: Data($0.utf8)) }
        for side in ArmSide.allCases {
            var selector = PoseSubjectSelector()
            var tracker = CurlTracker(side: side, exercise: .lateralRaise, runtimePolicy: .standard)
            var origin: Double?
            for row in rows where row.seconds >= label.segmentStartSeconds! && row.seconds < label.segmentEndSeconds! {
                let frame = try row.frame(), selection = selector.process(frame, side: side)
                if origin == nil { origin = frame.timestamp }
                tracker.process(selection.selectedFrame(from: frame), originalPeopleCount: frame.people.count, selection: selection)
            }
            XCTAssertEqual(tracker.repetitions.count, 5)
            try assertLabel(label, tracker.repetitions[label.candidateRepIndex].eccentric, origin: try XCTUnwrap(origin))
        }
    }
}
