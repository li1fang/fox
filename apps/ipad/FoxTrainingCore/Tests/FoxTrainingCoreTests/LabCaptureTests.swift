import XCTest
@testable import FoxTrainingCore

final class LabCaptureTests: XCTestCase {
    private func wire(_ tag: UInt8, _ payload: [UInt8]) -> Data {
        var b: [UInt8] = [0x53, UInt8(payload.count + 4), tag] + payload
        b.append(UInt8((256 - b.reduce(0) { ($0 + Int($1)) & 255 }) & 255))
        return Data(b)
    }
    func testManifestUnknownActionAndUnavailableStreamRoundTrip() throws {
        let source = LabCaptureSource(producer: "synthetic", version: "1", clockID: "host-1")
        let stream = LabCaptureStream(id: "pose3d", kind: "pose3d", state: "unavailable", reason: "unsupported",
                                      recordSchema: "fox.lab_pose3d.v1", source: source)
        let m = LabCaptureManifest(schema: "fox.lab_capture.v1", captureID: "synthetic-1", hostClockID: "host-1", mode: "free_capture",
                                   startedHostNS: "1", endedHostNS: "2", streams: [stream], files: [])
        let data = try JSONEncoder().encode(m)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["capture_id"] as? String, "synthetic-1")
        XCTAssertNil(json["action"])
        XCTAssertEqual(try JSONDecoder().decode(LabCaptureManifest.self, from: data), m)
    }
    func testFramePreservesPTSIntegerBeyondDoublePrecision() throws {
        let frame = LabFrameRecord(seq: 0, pts: .init(value: "9007199254740993", timescale: 30, epoch: "7"),
                                   originPTS: .init(value: "9007199254740990", timescale: 30, epoch: "7"), videoSeconds: 0.1,
                                   hostReceivedNS: 9007199254740993, state: "observed", reason: nil)
        let restored = try JSONDecoder().decode(LabFrameRecord.self, from: JSONEncoder().encode(frame))
        XCTAssertEqual(restored.pts.value, "9007199254740993")
        XCTAssertEqual(restored.pts.epoch, "7")
        XCTAssertEqual(restored.hostReceivedNS, "9007199254740993")
    }
    func testPumpLittleEndianZeroAndUnknownUnitsRemainRaw() {
        let raw = wire(3, [3,26,9,0x34,0x12,1,2,3,4,5,6,7,8,9,10,11,12])
        let reading = PumpTelemetryReading.decode(raw)
        XCTAssertEqual(reading.state, "decoded")
        XCTAssertEqual(reading.fields["repetitions_raw"], 0x1234)
        XCTAssertEqual(reading.fields["distance_raw"], 0x030201)
        XCTAssertNil(reading.fields["position_m"])
        XCTAssertNil(reading.fields["force_n"])
        XCTAssertEqual(PumpTelemetryReading.decode(wire(3, Array(repeating: 0, count: 17))).fields["cable_length_raw"], 0)
    }
    func testPumpCorruptionAndUnknownTypesKeepOriginalBytes() {
        let good = wire(3, Array(repeating: 0, count: 17))
        var bad = good; bad[bad.count-1] &+= 1
        for data in [bad, Data(good.dropLast()), good + good, Data(), wire(0x99, [1,2]), wire(1,[0,0])] {
            let result = PumpTelemetryReading.decode(data)
            XCTAssertNotEqual(result.state, "decoded")
            XCTAssertTrue(result.fields.isEmpty)
            XCTAssertEqual(result.rawHex, data.map { String(format: "%02x", $0) }.joined())
        }
    }
    func testPumpEventsKeepSeparateDeviceSegmentAndNoDeviceTick() throws {
        let raw = wire(2, [1,30,40,50,90,2,9])
        let a = PumpNotificationEvent(captureID: "c", deviceAlias: "pump-A", connectionSegmentID: "a1", hostClockID: "h", notificationSeq: 0, hostReceivedNS: 1, bytes: raw)
        let b = PumpNotificationEvent(captureID: "c", deviceAlias: "pump-B", connectionSegmentID: "b1", hostClockID: "h", notificationSeq: 0, hostReceivedNS: 2, bytes: raw)
        XCTAssertNotEqual(a.deviceAlias, b.deviceAlias)
        XCTAssertNotEqual(a.connectionSegmentID, b.connectionSegmentID)
        XCTAssertNil(a.deviceTick)
        XCTAssertEqual(try JSONDecoder().decode(PumpNotificationEvent.self, from: JSONEncoder().encode(a)), a)
    }
    func testPythonExportIsNativeReadableAndNativeWireIsPythonVerified() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { repo.deleteLastPathComponent() }
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOX_LAB_CROSS_ROOT"] ?? FileManager.default.temporaryDirectory.path).resolvingSymlinksInPath().appendingPathComponent("fox-lab-cross-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        func python(_ action: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3.12", repo.appendingPathComponent("scripts/lab_cross_language.py").path, action, base.path]
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "fox.lab.cross-language", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
            }
        }
        try python("prepare")
        let input = base.appendingPathComponent("native-input")
        let manifest = try JSONDecoder().decode(LabCaptureManifest.self, from: Data(contentsOf: input.appendingPathComponent("manifest.json")))
        XCTAssertNil(manifest.action)
        XCTAssertEqual(manifest.captureID, "synthetic-golden")
        let frame = try JSONDecoder().decode(LabFrameRecord.self, from: Data(contentsOf: input.appendingPathComponent("frames.jsonl")))
        XCTAssertEqual(frame.pts.value, "9007199254740993")
        let notification = try JSONDecoder().decode(PumpNotificationEvent.self, from: Data(contentsOf: input.appendingPathComponent("pump.jsonl")))
        XCTAssertEqual(notification.decoded, PumpTelemetryReading.decode(Data([0x53,0x15,0x03,0x03] + Array(repeating: 0, count: 16) + [0x92])))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let destination = base.appendingPathComponent("native-output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in manifest.files {
            try FileManager.default.copyItem(at: input.appendingPathComponent(file.path), to: destination.appendingPathComponent(file.path))
        }
        try encoder.encode(manifest).write(to: destination.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        // Encode constructors too, so the consumer cannot pass only by decoding its own format.
        let nativeFrame = LabFrameRecord(seq: frame.seq, pts: frame.pts, originPTS: frame.originPTS,
            videoSeconds: frame.videoSeconds, hostReceivedNS: 1000000000, state: "observed", reason: nil)
        let nativeEvent = PumpNotificationEvent(captureID: "synthetic-golden", deviceAlias: "pump-A", connectionSegmentID: "connection-1",
            hostClockID: "host-1", notificationSeq: 0, hostReceivedNS: 1000000000,
            bytes: Data([0x53,0x15,0x03,0x03] + Array(repeating: 0, count: 16) + [0x92]))
        try (encoder.encode(nativeFrame) + Data([10])).write(to: base.appendingPathComponent("native-frame.jsonl"))
        try (encoder.encode(nativeEvent) + Data([10])).write(to: base.appendingPathComponent("native-pump.jsonl"))
        try python("verify-native")
    }

    func testSharedPythonFrameReasonVectorsAreRejectedByNativeCodec() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { repo.deleteLastPathComponent() }
        let source = try Data(contentsOf: repo.appendingPathComponent("tests/fixtures/lab-capture/invalid-frame-reasons.json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let valid = LabFrameRecord(seq: 0, pts: .init(value: "0", timescale: 30), originPTS: .init(value: "0", timescale: 30),
                                   videoSeconds: 0, hostReceivedNS: 1, state: "observed", reason: nil)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        for vector in cases {
            var row = original
            for (key, value) in try XCTUnwrap(vector["updates"] as? [String: Any]) { row[key] = value }
            let data = try JSONSerialization.data(withJSONObject: row)
            XCTAssertThrowsError(try JSONDecoder().decode(LabFrameRecord.self, from: data), String(describing: vector["id"]))
        }
        for (state, reason) in [("dropped", Optional<String>.none), ("dropped", ""), ("observed", "")] {
            let invalid = LabFrameRecord(seq: 0, pts: valid.pts, originPTS: valid.originPTS,
                videoSeconds: 0, hostReceivedNS: 1, state: state, reason: reason)
            XCTAssertThrowsError(try JSONEncoder().encode(invalid))
        }
    }

    func testSharedManifestRejectionVectorsMatchTheNativeConsumerContract() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { repo.deleteLastPathComponent() }
        let base = repo.appendingPathComponent("tests/fixtures/lab-capture")
        let valid = try JSONDecoder().decode(LabCaptureManifest.self, from: Data(contentsOf: base.appendingPathComponent("synthetic-v1/manifest.json")))
        XCTAssertNoThrow(try valid.validate())
        var futureRows = valid
        futureRows.streams[0].recordSchema = "fox.future_raw.v99"
        let preserved = try JSONDecoder().decode(LabCaptureManifest.self, from: JSONEncoder().encode(futureRows))
        XCTAssertNoThrow(try preserved.validate())
        XCTAssertEqual(preserved.streams[0].recordSchema, "fox.future_raw.v99")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("invalid-manifests.json"))) as? [String: Any])
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        for vector in cases {
            let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(vector["manifest"]))
            XCTAssertThrowsError(try JSONDecoder().decode(LabCaptureManifest.self, from: data).validate(), String(describing: vector["id"]))
        }
    }

    func testPumpSubscriptionRefusesPreexistingOwnershipAndDoesNotReleaseIt() {
        var lease = PumpNotificationSubscription()
        XCTAssertEqual(PumpNotificationSubscription.adoptionRejection(hasExistingDelegate: false, alreadyNotifying: true), "existing_subscription")
        XCTAssertEqual(PumpNotificationSubscription.adoptionRejection(hasExistingDelegate: true, alreadyNotifying: false), "existing_delegate")
        XCTAssertNil(PumpNotificationSubscription.adoptionRejection(hasExistingDelegate: false, alreadyNotifying: false))
        XCTAssertFalse(lease.requestNewSubscription(alreadyNotifying: true))
        XCTAssertFalse(lease.release())
    }

    func testPumpSubscriptionOwnsOnlyItsRequestAndReleasesExactlyOnce() {
        var lease = PumpNotificationSubscription()
        XCTAssertFalse(lease.release(), "Stop before discovery owns no subscription")
        XCTAssertTrue(lease.requestNewSubscription(alreadyNotifying: false))
        XCTAssertTrue(lease.ownsSubscription)
        XCTAssertFalse(lease.requestNewSubscription(alreadyNotifying: true))
        XCTAssertTrue(lease.release(), "Pending or active own request can be cancelled")
        XCTAssertFalse(lease.release(), "Repeated stop must not unsubscribe again")
    }

}
