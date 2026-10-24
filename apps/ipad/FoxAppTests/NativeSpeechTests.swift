import AVFoundation
import FoxTrainingCore
import XCTest
@testable import Fox

@MainActor
final class NativeSpeechTests: XCTestCase {
    func testProductionSessionNotificationsDoNotCancelItsOwnSpeech() async throws {
        guard ProcessInfo.processInfo.environment["FOX_REAL_SPEECH"] == "1" else {
            throw XCTSkip("Explicit real-speech gate required")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechSession-\(UUID())")
        let store = TrainingStore(archiveURL: root.appendingPathComponent("training.json"), diagnosticRoot: root.appendingPathComponent("Diagnostics"))
        store.start()
        let guidance = GuidanceSession(vision: store.workoutVision.controller, store: store, driver: NativeSpeechOutput(), defaults: nil)
        defer { guidance.stop(); store.workoutVision.stop(); try? FileManager.default.removeItem(at: root) }
        guidance.start()
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !guidance.output.events.contains(where: { $0.state == "finished" }) && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let evidence = XCTAttachment(data: try JSONEncoder().encode(guidance.output.events), uniformTypeIdentifier: "public.json")
        evidence.name = "production-guidance-session-real-speech"; evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertTrue(guidance.output.events.contains { $0.state == "finished" && $0.outputKind == "system_speech_callback_not_audibility" },
                      "System-managed speech must survive the production route/interruption observers")
        XCTAssertFalse(guidance.output.events.contains { $0.state == "failed" })
        XCTAssertEqual(store.session?.stage, .ready)
        XCTAssertEqual(store.session?.records.count, 0)
    }

    func testExistingCachesAtRealSpeedThroughProductionSpeechScheduler() async throws {
        guard let path = ProcessInfo.processInfo.environment["FOX_GUIDANCE_REPLAY_INPUT"] else {
            throw XCTSkip("Explicit private replay input required; this is not a release pass")
        }
        struct Replay: Decodable { var name: String; var inputSHA256: String; var inputs: [GuidanceInput] }
        let replays = try JSONDecoder().decode([Replay].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let selected = replays.filter { ["curl-left", "raise-left", "pulldown-left"].contains($0.name) }
        XCTAssertEqual(selected.count, 3)
        for replay in selected {
            let output = GuidanceOutputController(driver: NativeSpeechOutput())
            let first = try XCTUnwrap(replay.inputs.first)
            let origin = ProcessInfo.processInfo.systemUptime
            for saved in replay.inputs {
                let target = origin + saved.time - first.time
                let wait = target - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                var input = saved
                input.time = ProcessInfo.processInfo.systemUptime
                if let observation = saved.motion {
                    input.motion?.observedAt = input.time - (saved.time - observation.observedAt)
                }
                output.update(input)
            }
            output.interrupt(reason: "replay_ended")
            let data = try JSONEncoder().encode(output.events)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "real-speed-\(replay.name)-\(replay.inputSHA256.prefix(12))"
            attachment.lifetime = .keepAlways; add(attachment)
            let counts = output.events.compactMap { $0.cue }.filter { $0.kind == .count }
            XCTAssertFalse(counts.isEmpty)
            XCTAssertFalse(output.events.contains { $0.state == "failed" }, replay.name)
            XCTAssertEqual(output.droppedEvents, 0)
            for count in counts {
                let starts = output.events.filter { $0.cueID == count.id && $0.state == "started" }
                XCTAssertEqual(starts.count, 1, "\(replay.name) \(count.text)")
                if let started = starts.first { XCTAssertLessThanOrEqual(started.time - count.createdAt, 1) }
            }
            let phases = output.events.compactMap { $0.cue }.filter { $0.kind == .phase }
            XCTAssertTrue(phases.contains { cue in output.events.contains { $0.cueID == cue.id && $0.state == "finished" } },
                          "No complete phase utterance in \(replay.name); evaluate shorter copy or summary-only capability")
        }
    }

    func testRealChineseSpeechStartsWithinBudgetAndFinishesWithoutMicrophone() async throws {
        guard ProcessInfo.processInfo.environment["FOX_REAL_SPEECH"] == "1" else {
            throw XCTSkip("Run the explicit real-speech gate; fake callbacks are not audio evidence")
        }
        XCTAssertNotNil(AVSpeechSynthesisVoice(language: "zh-CN"))
        let output = NativeSpeechOutput()
        var rows: [[String: Any]] = []
        for (index, phrase) in ["1", "放回", "返回", "这组结束了，感觉怎么样"].enumerated() {
            let finished = expectation(description: "real speech \(index)")
            let begin = ProcessInfo.processInfo.systemUptime
            var started: Double?, ended: Double?
            let id = "real-speech-\(index)"
            output.onEvent = { receivedID, event in
                XCTAssertEqual(receivedID, id)
                switch event {
                case .started: started = ProcessInfo.processInfo.systemUptime
                case .finished: ended = ProcessInfo.processInfo.systemUptime; finished.fulfill()
                case .failed, .cancelled: XCTFail("Unexpected real speech failure/cancellation"); finished.fulfill()
                }
            }
            let cue = GuidanceCue(id: id, context: .init(sessionID: "test", attemptID: "test", observationID: "test"),
                kind: .count, stage: .active, text: phrase, createdAt: begin, expiresAt: begin + 1)
            XCTAssertTrue(output.speak(cue))
            await fulfillment(of: [finished], timeout: 12)
            let start = try XCTUnwrap(started), end = try XCTUnwrap(ended)
            rows.append(["text": phrase, "startDelaySeconds": start - begin, "playbackSeconds": end - start,
                         "evidence": output.evidenceKind])
            if index == 0 { XCTAssertLessThanOrEqual(start - begin, 1, "Count start deadline") }
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "native-chinese-speech-callback-timing-not-audibility"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(AVAudioSession.sharedInstance().recordPermission, .undetermined)
    }
}
