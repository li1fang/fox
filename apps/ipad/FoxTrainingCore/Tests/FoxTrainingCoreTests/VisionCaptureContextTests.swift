import XCTest
@testable import FoxTrainingCore

final class VisionCaptureContextTests: XCTestCase {
    private func frame(scale: Double = 1, people: Int = 1) -> PoseFrame {
        let points: [PoseJoint: PosePoint] = [.neck: PosePoint(x: 0.5, y: 0.5 + 0.3 * scale),
            .root: PosePoint(x: 0.5, y: 0.5), .leftShoulder: PosePoint(x: 0.5 - 0.1 * scale, y: 0.5 + 0.25 * scale),
            .rightShoulder: PosePoint(x: 0.5 + 0.1 * scale, y: 0.5 + 0.25 * scale),
            .leftElbow: PosePoint(x: 0.5 - 0.1 * scale, y: 0.5 + 0.1 * scale),
            .leftWrist: PosePoint(x: 0.5 - 0.1 * scale, y: 0.5 - 0.05 * scale),
            .nose: PosePoint(x: 0, y: 1)]
        return PoseFrame(timestamp: 0, width: 1280, height: 720, people: Array(repeating: BodyPose(points: points), count: people))
    }
    private func record(_ recorder: inout VisionContextRecorder, at seconds: Double, pose: VisionDevicePose? = nil, people: Int = 1) {
        recorder.record(elapsedSeconds: seconds, screenOrientation: .landscapeLeft,
            motionStatus: pose == nil ? .unavailable : .fixture, devicePose: pose, frame: frame(people: people),
            side: .left, automaticCount: 0, interruptions: 0)
    }

    func testScreenAngleAndCameraElevationConventions() throws {
        for (z, screen, elevation) in [(-1.0, 0.0, 90.0), (0, 90, 0), (1, 180, -90)] {
            let pose = try XCTUnwrap(VisionDevicePose.measure(gravityX: 0, gravityY: z == 0 ? -1 : 0, gravityZ: z, frontCamera: true, source: .fixture))
            XCTAssertEqual(pose.screenInclinationDegrees, screen, accuracy: 0.001)
            XCTAssertEqual(pose.cameraElevationDegrees, elevation, accuracy: 0.001)
            try pose.validate(frontCamera: true)
        }
        let verticalLandscape = try XCTUnwrap(VisionDevicePose.measure(gravityX: -1, gravityY: 0, gravityZ: 0, frontCamera: false, source: .fixture))
        XCTAssertEqual(verticalLandscape.screenInclinationDegrees, 90, accuracy: 0.001)
        let tiltedFront = try XCTUnwrap(VisionDevicePose.measure(gravityX: 0, gravityY: -sqrt(0.75), gravityZ: -0.5, frontCamera: true, source: .fixture))
        let tiltedBack = try XCTUnwrap(VisionDevicePose.measure(gravityX: 0, gravityY: -sqrt(0.75), gravityZ: -0.5, frontCamera: false, source: .fixture))
        XCTAssertEqual(tiltedFront.screenInclinationDegrees, 60, accuracy: 0.001)
        XCTAssertEqual(tiltedFront.cameraElevationDegrees, 30, accuracy: 0.001)
        XCTAssertEqual(tiltedBack.cameraElevationDegrees, -30, accuracy: 0.001)
    }

    func testInvalidGravityIsMissingRatherThanZeroDegrees() {
        XCTAssertNil(VisionDevicePose.measure(gravityX: 0, gravityY: 0, gravityZ: 0, frontCamera: true, source: .fixture))
        XCTAssertNil(VisionDevicePose.measure(gravityX: .nan, gravityY: 1, gravityZ: 0, frontCamera: true, source: .fixture))
    }

    func testImageScaleExcludesFaceAndIsNotMetricDistance() throws {
        let large = try XCTUnwrap(VisionFraming.measure(frame()))
        let small = try XCTUnwrap(VisionFraming.measure(frame(scale: 0.5)))
        XCTAssertEqual(large.visibleBodyPoints, 6)
        XCTAssertEqual(large.observedHeightFraction, 0.35, accuracy: 0.001)
        XCTAssertEqual(small.torsoHeightFraction!, large.torsoHeightFraction! / 2, accuracy: 0.001)
        XCTAssertEqual(large.shoulderWidthFraction!, 0.2, accuracy: 0.001)
        XCTAssertFalse(large.nearImageEdge)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalTrainingRepository.encoder().encode(large)) as? [String: Any])
        XCTAssertNil(object["distanceMeters"]); XCTAssertNil(object["points"])
    }

    func testAbsentAmbiguousAndLowConfidencePeopleDoNotReuseScale() {
        XCTAssertNil(VisionFraming.measure(frame(people: 0)))
        XCTAssertNil(VisionFraming.measure(frame(people: 2)))
        var low = frame()
        low.people[0].points = low.people[0].points.mapValues { PosePoint(x: $0.x, y: $0.y, confidence: 0.1) }
        XCTAssertNil(VisionFraming.measure(low))
    }

    func testRecorderIsThrottledBoundedAndKeepsMissingObservations() {
        var recorder = VisionContextRecorder()
        record(&recorder, at: 0); record(&recorder, at: 0.1); record(&recorder, at: -1)
        XCTAssertEqual(recorder.samples.count, 1)
        record(&recorder, at: 1, people: 0)
        XCTAssertNil(recorder.samples.last?.framing)
        XCTAssertNil(recorder.samples.last?.devicePose)
        for second in 2...1802 { record(&recorder, at: Double(second)) }
        XCTAssertEqual(recorder.samples.count, 1800)
        XCTAssertEqual(recorder.droppedSamples, 3)
    }

    func testContextRoundTripAndOldReportsRemainCompatible() throws {
        var recorder = VisionContextRecorder()
        let pose = VisionDevicePose.measure(gravityX: 0, gravityY: -1, gravityZ: 0, frontCamera: true, source: .fixture)
        record(&recorder, at: 0, pose: pose)
        let context = VisionCaptureContext(declaredBodyView: .mixed, samples: recorder.samples)
        let date = Date(timeIntervalSince1970: 1700000000)
        let report = VisionTrial(startedAt: date, endedAt: date.addingTimeInterval(10), device: "fixture", appVersion: "0.3.2",
            visionRevision: 1, source: .fixture, camera: "front", arm: .left, repetitions: [],
            manualAdjustment: 0, referenceCount: nil, metrics: VisionMetrics(), notes: "", captureContext: context)
        try report.validate()
        let data = try LocalTrainingRepository.encoder().encode(report)
        let loaded = try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: data)
        XCTAssertEqual(loaded.captureContext, context)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "captureContext")
        let legacy = try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: JSONSerialization.data(withJSONObject: object))
        try legacy.validate()
        XCTAssertNil(legacy.captureContext)
        XCTAssertEqual(legacy.id, report.id)
    }

    func testInvalidMetadataAndFixtureCannotBecomeRealEvidence() throws {
        var recorder = VisionContextRecorder()
        record(&recorder, at: 0, pose: VisionDevicePose.measure(gravityX: 0, gravityY: -1, gravityZ: 0, frontCamera: true, source: .fixture))
        var context = VisionCaptureContext(declaredBodyView: .side, samples: recorder.samples)
        XCTAssertThrowsError(try context.validate(frontCamera: true, source: .camera))
        context.samples[0].devicePose?.screenInclinationDegrees = 0
        XCTAssertThrowsError(try context.validate(frontCamera: true, source: .fixture))
        context = VisionCaptureContext(declaredBodyView: .unknown, samples: recorder.samples)
        context.bodyViewSource = "automatic"
        XCTAssertThrowsError(try context.validate(frontCamera: true, source: .fixture))
        context = VisionCaptureContext(declaredBodyView: .side, samples: recorder.samples + recorder.samples)
        XCTAssertThrowsError(try context.validate(frontCamera: true, source: .fixture))
        context = VisionCaptureContext(declaredBodyView: .side, samples: recorder.samples)
        context.samples[0].motionStatus = .unavailable
        XCTAssertThrowsError(try context.validate(frontCamera: true, source: .fixture))
        context.samples[0].motionStatus = .fixture
        context.samples[0].devicePose = nil
        XCTAssertThrowsError(try context.validate(frontCamera: true, source: .fixture))
    }
}
