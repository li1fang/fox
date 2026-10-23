import CryptoKit
import FoxTrainingCore
import XCTest
import FoxTestSupport
@testable import Fox

@MainActor
final class VisionReplayBatchTests: XCTestCase {
    private func fixture(_ exercise: VisionExercise = .curl, _ side: ArmSide = .left) throws -> (URL, UUID) {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent("FoxBatch-\(UUID())")
        let id = UUID(), input = documents.appendingPathComponent("FoxReplay/Jobs/\(id.uuidString)")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: documents) }
        let cycle = exercise == .curl ? [160.0,160,160,160,160,140,120,100,80,55,55,55,55,75,100,100,120,120,140,140,160,160,160,160,160,160]
            : [10.0,10,10,10,10,25,40,55,65,70,85,85,85,85,75,65,55,45,35,25,15,10,10,10,10,10,10]
        var data = try JSONSerialization.data(withJSONObject: ["schema":"fox.pose_comparison_cache.v1", "source":"synthetic-fixture",
            "videoSHA256":String(repeating: "0", count: 64), "platform":"fixture", "visionRevision":"1", "sampledHz":"10"])
        data.append(10)
        for (i, angle) in (Array(repeating: cycle[0], count: 36) + cycle + cycle).enumerated() {
            let r = angle * .pi / 180, d = side == .left ? 1.0 : -1.0
            var points = [side.joints[0]: PosePoint(x: 0.48, y: 0.8)]
            if exercise == .curl {
                points[side.joints[1]] = PosePoint(x: 0.48, y: 0.55)
                points[side.joints[2]] = PosePoint(x: 0.48 + d * sin(r) * 0.22 * 720 / 1280, y: 0.55 + cos(r) * 0.22)
            } else {
                points[side.joints[1]] = PosePoint(x: 0.48 - d * sin(r) * 0.22 * 720 / 1280, y: 0.8 - cos(r) * 0.22)
                points[side == .left ? .leftHip : .rightHip] = PosePoint(x: 0.48, y: 0.43)
            }
            let row = PoseVideoRow(seconds: Double(i) / 10, width: 1280, height: 720,
                people: [points.map { PoseTraceJoint(joint: $0.key, x: $0.value.x, y: $0.value.y, confidence: $0.value.confidence) }])
            data.append(try JSONEncoder().encode(row)); data.append(10)
        }
        try data.write(to: input.appendingPathComponent("input.jsonl"))
        let asset = try VisionDiagnosticArchive.asset(input.appendingPathComponent("input.jsonl"))
        let job: [String: Any] = ["schema":"fox.vision_batch_job.v1", "id":id.uuidString, "kind":"cache", "input":"input.jsonl",
            "files":[["path":asset.path,"bytes":asset.bytes,"sha256":asset.sha256]],
            "cases":[["id":"full","exercise":exercise.rawValue,"arm":side.rawValue,"startSeconds":0,"endSeconds":10,"rebindAtSeconds":[]]]]
        try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys]).write(to: input.appendingPathComponent("job.json"))
        return (documents, id)
    }
    private func edit(_ documents: URL, _ id: UUID, change: (inout [String: Any]) -> Void) throws {
        let url = documents.appendingPathComponent("FoxReplay/Jobs/\(id.uuidString)/job.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        change(&value)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }
    private func status(_ documents: URL, _ id: UUID) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: documents.appendingPathComponent("FoxReplayRuns/\(id.uuidString)/status.json"))) as! [String: Any]
    }
    private func failure(_ documents: URL, _ id: UUID, control: VisionBatchControl = .init()) async {
        do { _ = try await VisionReplayBatch.run(id: id, documents: documents, control: control); XCTFail("Invalid/cancelled task succeeded") }
        catch {}
    }

    func testCacheUsesRealControllerForBothActionsAndSidesWithoutVideo() async throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            let (documents, id) = try fixture(exercise, side)
            let result = try await VisionReplayBatch.run(id: id, documents: documents)
            XCTAssertEqual(result.cases.first?.repetitions.count, 2)
            XCTAssertFalse(result.inferencePerformed)
            XCTAssertEqual(result.controllerVersion, VisionLabController.preparationFlowVersion)
            XCTAssertEqual(result.settings.runtimePolicy, .standard)
            XCTAssertTrue(result.cases[0].repetitions.allSatisfy { $0.eccentric != nil })
            XCTAssertEqual(try status(documents, id)["phase"] as? String, "completed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("FoxReplayRuns/\(id.uuidString)/vision.jsonl").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("Fox").path))
        } }
    }

    func testCompletedRunIsImmutableAndInputsAreUnchanged() async throws {
        let (documents, id) = try fixture()
        let input = documents.appendingPathComponent("FoxReplay/Jobs/\(id.uuidString)/input.jsonl")
        let before = try Data(contentsOf: input)
        _ = try await VisionReplayBatch.run(id: id, documents: documents)
        let output = documents.appendingPathComponent("FoxReplayRuns/\(id.uuidString)/status.json")
        let receipt = try Data(contentsOf: output)
        await failure(documents, id)
        XCTAssertEqual(try Data(contentsOf: output), receipt)
        XCTAssertEqual(try Data(contentsOf: input), before)
    }

    func testObservationOnlyModeDoesNotStartControllerOrWriteTraining() async throws {
        let (documents, id) = try fixture()
        try edit(documents, id) { $0["mode"] = "observations"; $0["cases"] = [] }
        let result = try await VisionReplayBatch.run(id: id, documents: documents)
        let value = try JSONSerialization.jsonObject(with: VisionDiagnosticArchive.encode(result)) as! [String: Any]
        XCTAssertEqual(value["mode"] as? String, "observations")
        XCTAssertEqual(value["observationFrameCount"] as? Int, 88)
        XCTAssertEqual(result.controllerVersion, "not-run")
        XCTAssertTrue(result.cases.isEmpty)
        XCTAssertTrue(result.algorithms.isEmpty)
        XCTAssertFalse(result.inferencePerformed)
        XCTAssertEqual(try status(documents, id)["processedFrames"] as? Int, 88)
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("Fox").path))
    }

    func testObservationModeRejectsCounterCasesDiagnosticAndUnknownMode() async throws {
        for invalid in ["cases", "diagnostic", "mode"] {
            let (documents, id) = try fixture()
            try edit(documents, id) { job in
                job["mode"] = invalid == "mode" ? "future" : "observations"
                if invalid != "cases" { job["cases"] = [] }
                if invalid == "diagnostic" { job["kind"] = "diagnostic" }
            }
            await failure(documents, id)
            XCTAssertEqual(try status(documents, id)["phase"] as? String, "failed")
        }
    }

    func testObservationModeCancelledBeforePublishingCannotComplete() async throws {
        let (documents, id) = try fixture(), control = VisionBatchControl()
        try edit(documents, id) { $0["mode"] = "observations"; $0["cases"] = [] }
        do {
            _ = try await VisionReplayBatch.run(id: id, documents: documents, control: control) { phase, _ in
                if phase == "observing" { control.stop("backgrounded") }
            }
            XCTFail("Cancelled observations were published")
        } catch {}
        XCTAssertEqual(try status(documents, id)["phase"] as? String, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("FoxReplayRuns/\(id.uuidString)/result.json").path))
    }

    func testDeviceTransferredReadOnlyInboxDoesNotOwnOutputDirectory() async throws {
        let (documents, id) = try fixture()
        let inbox = documents.appendingPathComponent("FoxReplay")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: inbox.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inbox.path) }
        let result = try await VisionReplayBatch.run(id: id, documents: documents)
        XCTAssertEqual(result.cases.first?.repetitions.count, 2)
        XCTAssertEqual(try status(documents, id)["phase"] as? String, "completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("Runs").path))
    }

    func testBadDigestUnsafePathUnknownSchemaAndEmptySegmentAreRejected() async throws {
        for invalid in ["digest", "path", "schema", "empty", "duplicateCase", "badSettings"] {
            let (documents, id) = try fixture()
            try edit(documents, id) { job in
                if invalid == "digest" { var files = job["files"] as! [[String:Any]]; files[0]["sha256"] = String(repeating: "f", count: 64); job["files"] = files }
                if invalid == "path" { job["input"] = "../input.jsonl" }
                if invalid == "schema" { job["schema"] = "future" }
                if invalid == "empty" { var cases = job["cases"] as! [[String:Any]]; cases[0]["startSeconds"] = 100; cases[0]["endSeconds"] = 101; job["cases"] = cases }
                if invalid == "duplicateCase" { job["cases"] = (job["cases"] as! [[String:Any]]) + (job["cases"] as! [[String:Any]]) }
                if invalid == "badSettings" { job["settings"] = ["schema":"future"] }
            }
            await failure(documents, id)
            XCTAssertEqual(try status(documents, id)["phase"] as? String, "failed", invalid)
        }
    }

    func testCancelledOrBackgroundedRunCannotProduceSuccess() async throws {
        for reason in ["userCancelled", "backgrounded"] {
            let (documents, id) = try fixture(), control = VisionBatchControl()
            do {
                _ = try await VisionReplayBatch.run(id: id, documents: documents, control: control) { _, frames in
                    if frames >= 20 { control.stop(reason) }
                }
                XCTFail("Stopped run succeeded")
            } catch {}
            XCTAssertEqual(try status(documents, id)["phase"] as? String, "cancelled")
            XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("FoxReplayRuns/\(id.uuidString)/result.json").path))
        }
    }

    func testNonmonotonicCacheAndUnsupportedHeaderCannotComplete() async throws {
        for invalid in ["time", "header"] {
            let (documents, id) = try fixture()
            let file = documents.appendingPathComponent("FoxReplay/Jobs/\(id.uuidString)/input.jsonl")
            var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
            if invalid == "time" { lines[2] = lines[1] }
            else { lines[0] = "{\"schema\":\"unknown\"}" }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
            let asset = try VisionDiagnosticArchive.asset(file)
            try edit(documents, id) { $0["files"] = [["path":asset.path,"bytes":asset.bytes,"sha256":asset.sha256]] }
            await failure(documents, id)
            XCTAssertEqual(try status(documents, id)["phase"] as? String, "failed")
        }
    }

    func testPrivateM4CacheBatchPreservesFourControllerCountsAndMeasuredPhases() async throws {
        let input = try PrivateFixtures.url("reference.cache")
        let (documents, id) = try fixture()
        let file = documents.appendingPathComponent("FoxReplay/Jobs/\(id.uuidString)/input.jsonl")
        let data = try Data(contentsOf: input)
        XCTAssertEqual(VisionReplayBatch.digest(data), "84f2651a2f8b5fc1fd71c6a98e5b43f66ac8afb70ae3f8d12e6db2948af7f7f7")
        try data.write(to: file)
        let asset = try VisionDiagnosticArchive.asset(file)
        try edit(documents, id) { job in
            job["files"] = [["path":asset.path,"bytes":asset.bytes,"sha256":asset.sha256]]
            job["cases"] = [
                ["id":"A01-left", "exercise":"curl", "arm":"left", "startSeconds":7, "endSeconds":60, "rebindAtSeconds":[]],
                ["id":"A02-right", "exercise":"curl", "arm":"right", "startSeconds":60, "endSeconds":107, "rebindAtSeconds":[]],
                ["id":"A03-left", "exercise":"lateralRaise", "arm":"left", "startSeconds":120, "endSeconds":155, "rebindAtSeconds":[]],
                ["id":"A03-right", "exercise":"lateralRaise", "arm":"right", "startSeconds":120, "endSeconds":155, "rebindAtSeconds":[]]
            ]
        }
        let result = try await VisionReplayBatch.run(id: id, documents: documents)
        XCTAssertEqual(result.cases.map { $0.repetitions.count }, [9,9,4,4])
        for item in result.cases {
            XCTAssertNotNil(item.originSeconds)
            XCTAssertTrue(item.repetitions.allSatisfy { $0.eccentric != nil })
            XCTAssertEqual(item.trace.last?.automaticCount, item.repetitions.count)
        }
        let attachment = XCTAttachment(data: try VisionDiagnosticArchive.encode(result), uniformTypeIdentifier: "public.json")
        attachment.name = "M2-M4-cache-batch-simulator"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPrivatePulldownFullControllerSixPeaksAndNoTerminalDuration() async throws {
        let input = try PrivateFixtures.url("pulldown.cache")
        let (documents, id) = try fixture()
        let file = documents.appendingPathComponent("FoxReplay/Jobs/\(id.uuidString)/input.jsonl")
        let data = try Data(contentsOf: input)
        XCTAssertEqual(VisionReplayBatch.digest(data), "991eada7dff21ced337ecf44d792b0cc0e48dc5eecbd2f8b48bb334f04f7ceea")
        try data.write(to: file)
        let asset = try VisionDiagnosticArchive.asset(file)
        try edit(documents, id) { job in
            job["files"] = [["path":asset.path,"bytes":asset.bytes,"sha256":asset.sha256]]
            job["cases"] = ArmSide.allCases.flatMap { side in [61.5,48.8].map { end -> [String: Any] in
                ["id":"pulldown-\(side.rawValue)-\(end)", "exercise":"latPulldown", "arm":side.rawValue,
                 "startSeconds":0, "endSeconds":end, "rebindAtSeconds":[]]
            } }
        }
        let result = try await VisionReplayBatch.run(id: id, documents: documents)
        let evidence = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["FOX_M3_EVIDENCE_DIR"]))
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try VisionDiagnosticArchive.encode(result).write(to: evidence.appendingPathComponent("controller-cache-result.json"))
        for item in result.cases {
            XCTAssertEqual(item.repetitions.count, 6, item.specification.id)
            let origin = try XCTUnwrap(item.originSeconds)
            XCTAssertLessThan(origin, 16.5, "Start before first pull, not at its peak")
            let windows = [17.0...19.4,22.8...24.9,28.5...30.9,34.4...36.7,40.6...42.5,46.6...49.0]
            for (index, rep) in item.repetitions.prefix(6).enumerated() {
                XCTAssertTrue(windows[index].contains(rep.completedAtSeconds + origin), "event \(index): \(rep.completedAtSeconds + origin)")
                XCTAssertNil(rep.lowerSeconds); XCTAssertNil(rep.eccentric)
                XCTAssertEqual(rep.countingBasis, .contractedEndpoint)
            }
            XCTAssertEqual(item.repetitions.compactMap(\.precedingReturn).map(\.repetitionIndex), [0,1,2,3,4])
            XCTAssertEqual(item.repetitions.compactMap { $0.precedingReturn?.measurement.status }, Array(repeating: .measured, count: 5))
        }
        XCTAssertEqual(result.cases[0].repetitions, result.cases[1].repetitions)
        XCTAssertEqual(result.cases[2].repetitions, result.cases[3].repetitions)
    }
}
