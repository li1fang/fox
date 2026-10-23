import CryptoKit
import Foundation
import XCTest
import FoxTestSupport
@testable import FoxTrainingCore

final class GuidanceReplayTests: XCTestCase {
    private struct CaseEvidence: Encodable {
        var name: String
        var inputSHA256: String
        var frames: Int
        var inputs: [GuidanceInput]
        var repetitions: [CurlRepetition]
        var cues: [GuidanceCue]
        var observedFollowExamples: Int
        var verdict: String
        var terminalReturnNotInvented: Bool
    }

    func testExistingVideoCachesGuidanceCausalAndMotionFactsUnchanged() throws {
        let caches = [
            ("reference.cache", "84f2651a2f8b5fc1fd71c6a98e5b43f66ac8afb70ae3f8d12e6db2948af7f7f7"),
            ("pulldown.cache", "991eada7dff21ced337ecf44d792b0cc0e48dc5eecbd2f8b48bb334f04f7ceea")
        ]
        var decoded: [[PoseVideoRow]] = []
        for (path, digest) in caches {
            let url = try PrivateFixtures.url(path)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), digest)
            let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
            decoded.append(try lines.dropFirst().map { try JSONDecoder().decode(PoseVideoRow.self, from: Data($0.utf8)) })
        }
        var evidence: [CaseEvidence] = []
        for (name, cache, exercise, side, start, end, count) in [
            ("curl-left", 0, VisionExercise.curl, ArmSide.left, 7.0, 60.0, 9),
            ("curl-right", 0, .curl, .right, 60.0, 107.0, 9),
            ("raise-left", 0, .lateralRaise, .left, 120.0, 155.0, 4),
            ("raise-right", 0, .lateralRaise, .right, 120.0, 155.0, 4),
            ("pulldown-left", 1, .latPulldown, .left, 0.0, 61.5, 6),
            ("pulldown-right", 1, .latPulldown, .right, 0.0, 61.5, 6),
            ("pulldown-terminal-peak", 1, .latPulldown, .left, 0.0, 48.8, 6)
        ] {
            var selector = PoseSubjectSelector(policy: .standard)
            var gate = PoseStartGate(lossTolerance: PoseRuntimePolicy.standard.countdownLossTolerance)
            gate.arm()
            var tracker = CurlTracker(side: side, exercise: exercise, runtimePolicy: .standard)
            var control = CurlTracker(side: side, exercise: exercise, runtimePolicy: .standard)
            var policy = GuidancePolicy(), off = GuidancePolicy()
            var began = false
            var inputs: [GuidanceInput] = [], outputs: [GuidanceUpdate] = []
            for row in decoded[cache] where row.seconds >= start && row.seconds < end {
                let frame = try row.frame(), selected = selector.process(frame, side: side)
                let subject = selected.selectedFrame(from: frame)
                if !began {
                    began = gate.process(timestamp: frame.timestamp,
                        poseReady: PoseSubjectSelector.isReady(subject, side: side, confidence: PoseRuntimePolicy.standard.subjectConfidence)) == .ready
                }
                if began {
                    tracker.process(subject, originalPeopleCount: frame.people.count, selection: selected)
                    control.process(subject, originalPeopleCount: frame.people.count, selection: selected)
                }
                let stage: GuidanceStage
                let countdown: Int?
                if began { stage = .active; countdown = nil }
                else if case .countdown(let n) = gate.state { stage = .countdown; countdown = n }
                else { stage = .preparing; countdown = nil }
                let input = GuidanceInput(context: .init(sessionID: name, attemptID: "1", observationID: "1"),
                    time: row.seconds, stage: stage, exercise: exercise, mode: .observed,
                    count: tracker.repetitions.count, targetReps: nil,
                    motion: .init(observedAt: row.seconds, snapshot: tracker.snapshot), tempo: [], elapsed: row.seconds - start, countdown: countdown)
                inputs.append(input); outputs.append(policy.update(input))
                var silent = input; silent.mode = .off
                XCTAssertTrue(off.update(silent).cues.isEmpty)
                XCTAssertEqual(tracker.repetitions, control.repetitions, "\(name) facts @\(row.seconds)")
                XCTAssertEqual(tracker.diagnostics.resetCounts, control.diagnostics.resetCounts)
            }
            XCTAssertEqual(tracker.repetitions.count, count, name)
            let cues = outputs.flatMap(\.cues)
            XCTAssertEqual(cues.filter { $0.kind == .count }.count, count, name)
            var examples = 0
            for index in outputs.indices {
                for cue in outputs[index].cues where cue.kind == .phase {
                    XCTAssertTrue(cue.isValid(at: inputs[index].time, context: inputs[index].context,
                        stage: inputs[index].stage, phaseToken: outputs[index].presentation.phaseToken))
                    if let later = inputs.indices.first(where: { inputs[$0].time >= cue.createdAt + 0.35 }),
                       outputs[later].presentation.phaseToken == cue.phaseToken { examples += 1 }
                }
                if index % 31 == 0 {
                    var prefix = GuidancePolicy()
                    var last: GuidanceUpdate?
                    for sample in inputs.prefix(index + 1) { last = prefix.update(sample) }
                    XCTAssertEqual(last, outputs[index], "\(name) prefix @\(index)")
                }
            }
            let terminalSafe = exercise != .latPulldown ||
                (tracker.repetitions.last?.eccentric == nil &&
                 !tracker.repetitions.contains { $0.precedingReturn?.repetitionIndex == count - 1 })
            XCTAssertTrue(terminalSafe)
            evidence.append(.init(name: name, inputSHA256: caches[cache].1, frames: inputs.count, inputs: inputs,
                repetitions: tracker.repetitions, cues: cues, observedFollowExamples: examples,
                verdict: examples > 0 ? "observed_follow_sample_available" : "summary_only", terminalReturnNotInvented: terminalSafe))
        }
        XCTAssertTrue(evidence.contains { $0.observedFollowExamples > 0 }, "All actions summary-only would shrink the agreed scope")
        if let output = ProcessInfo.processInfo.environment["FOX_GUIDANCE_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(evidence).write(to: directory.appendingPathComponent("guidance-cache-evidence.json"), options: .atomic)
        }
    }
}
