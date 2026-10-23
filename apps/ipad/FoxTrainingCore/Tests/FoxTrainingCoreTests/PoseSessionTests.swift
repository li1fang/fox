import XCTest
@testable import FoxTrainingCore

final class PoseSessionTests: XCTestCase {
    private func person(x: Double, y: Double = 0.8) -> BodyPose {
        BodyPose(points: [.leftShoulder: PosePoint(x: x, y: y), .leftElbow: PosePoint(x: x, y: y - 0.2),
                          .leftWrist: PosePoint(x: x, y: y - 0.4), .leftHip: PosePoint(x: x, y: y - 0.35)])
    }
    private func frame(_ people: [BodyPose], _ t: Double) -> PoseFrame { PoseFrame(timestamp: t, width: 1280, height: 720, people: people) }
    func testSubjectBindingIgnoresBackgroundAndObservationOrder() {
        var selector = PoseSubjectSelector()
        let subject = person(x: 0.48), background = person(x: 0.85, y: 0.5)
        XCTAssertEqual(selector.process(frame([background, subject], 0)).index, 1)
        XCTAssertEqual(selector.process(frame([subject, background], 0.1)).index, 0)
        XCTAssertEqual(selector.process(frame([person(x: 0.2), subject, background], 0.2)).index, 1)
    }
    func testAmbiguousSubjectsAreNotChosenByLargestOrOrder() {
        var selector = PoseSubjectSelector()
        XCTAssertEqual(selector.process(frame([person(x: 0.48), person(x: 0.49)], 0)).state, .ambiguous)
        XCTAssertNil(selector.selection.index)
    }
    func testNewAcquisitionIsExplicitAndArchivedPoliciesKeepOldBehavior() throws {
        var legacy = PoseRuntimePolicy.standard
        legacy.acquisitionMode = nil
        let restored = try JSONDecoder().decode(PoseRuntimePolicy.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(restored.acquisitionMode)
        var old = PoseSubjectSelector(policy: restored), current = PoseSubjectSelector()
        XCTAssertEqual(old.process(frame([person(x: 0.2)], 0), side: .left).state, .waiting)
        XCTAssertEqual(current.process(frame([person(x: 0.2)], 0), side: .left).state, .bound)
        current.reset()
        XCTAssertEqual(current.process(frame([person(x: 0.2)], 0), side: .right).state, .waiting)
        current.reset()
        XCTAssertEqual(current.process(frame([person(x: 0.2), person(x: 0.9)], 0), side: .left).state, .waiting)
        current.reset()
        var missingElbow = person(x: 0.2)
        missingElbow.points.removeValue(forKey: .leftElbow)
        XCTAssertEqual(current.process(frame([missingElbow], 0), side: .left).state, .waiting)
    }
    func testLeavingNeverHandsSessionToBystanderAndExplicitRebindWorks() {
        var selector = PoseSubjectSelector()
        selector.process(frame([person(x: 0.48)], 0))
        XCTAssertEqual(selector.process(frame([person(x: 0.85)], 0.1)).state, .occluded)
        XCTAssertEqual(selector.process(frame([person(x: 0.48)], 1.5)).state, .lost)
        XCTAssertEqual(selector.process(frame([person(x: 0.48)], 1.6)).state, .lost)
        selector.reset()
        XCTAssertEqual(selector.process(frame([person(x: 0.48)], 1.7)).state, .bound)
    }
    func testStartDoesNotRequireWristHipOrOppositeArm() {
        var subject = person(x: 0.48)
        subject.points.removeValue(forKey: .leftWrist); subject.points.removeValue(forKey: .leftHip)
        XCTAssertTrue(PoseSubjectSelector.isReady(frame([subject], 0), side: .left))
        XCTAssertFalse(PoseSubjectSelector.isReady(frame([subject], 0), side: .right))
    }
    func testBriefCountdownLossPreservesDeadlineButCannotStartOnMissingFrame() {
        var gate = PoseStartGate(lossTolerance: 0.35)
        gate.arm()
        for i in 0...32 { gate.process(timestamp: Double(i) / 10, poseReady: i != 15) }
        XCTAssertEqual(gate.state, .countdown(1))
        gate.process(timestamp: 3.3, poseReady: false)
        XCTAssertNotEqual(gate.state, .ready)
        XCTAssertEqual(gate.process(timestamp: 3.4, poseReady: true), .ready)
        gate.arm()
        for i in 0...10 { gate.process(timestamp: Double(i) / 10, poseReady: true) }
        for i in 11...16 { gate.process(timestamp: Double(i) / 10, poseReady: false) }
        XCTAssertEqual(gate.state, .waiting)
    }
    private func curl(_ angle: Double, _ t: Double, _ confidence: Double = 1) -> PoseFrame {
        let r = angle * .pi / 180
        var p = person(x: 0.48)
        p.points[.leftWrist] = PosePoint(x: 0.48 + sin(r) * 0.18 * 720 / 1280, y: 0.6 + cos(r) * 0.18, confidence: confidence)
        return frame([p], t)
    }
    func testObserved149DegreeBottomCountsOnlyInV3AndReplaysExactly() throws {
        var v3 = PoseRuntimePolicy.standard
        v3.curlRecovery = nil; v3.eccentricPolicy = nil
        var old = CurlTracker(side: .left), new = CurlTracker(side: .left, runtimePolicy: v3)
        let angles = [149.0,149,149,149,149,135,125,110,95,80,55,55,55,55,55,80,100,115,130,149,149,149,149]
        for (i, a) in angles.enumerated() { old.process(curl(a, Double(i)/10)); new.process(curl(a, Double(i)/10)) }
        XCTAssertEqual(old.repetitions.count, 0); XCTAssertEqual(new.repetitions.count, 1)
        let report = VisionTrial(startedAt: .distantPast, endedAt: .distantFuture, device: "fixture", appVersion: "0.3.5", visionRevision: 1,
                                 source: .fixture, camera: "front", arm: .left, repetitions: new.repetitions, manualAdjustment: 0,
                                 referenceCount: 1, metrics: .init(), notes: "", counterDiagnostics: new.diagnostics)
        XCTAssertEqual(report.algorithm, "curl_2d_v3")
        XCTAssertEqual(try PoseReplay.replay(report).repetitions, new.repetitions)
    }
    func testLongerOcclusionOnlyAtConfirmedBottomNeverCreatesMotion() {
        var tracker = CurlTracker(side: .left, runtimePolicy: .standard)
        for i in 0...4 { tracker.process(curl(160, Double(i)/10)) }
        for i in 5...10 { tracker.process(curl(160, Double(i)/10, 0.1)) }
        XCTAssertEqual(tracker.snapshot.phase, .lowered)
        XCTAssertEqual(tracker.repetitions.count, 0)
        tracker.process(curl(160, 1.1))
        XCTAssertEqual(tracker.snapshot.phase, .lowered)
        tracker.process(curl(120, 1.2))
        tracker.process(curl(120, 1.3))
        tracker.process(curl(120, 1.4))
        XCTAssertEqual(tracker.snapshot.phase, .raising)
        for i in 15...20 { tracker.process(curl(55, Double(i)/10, 0.1)) }
        XCTAssertEqual(tracker.snapshot.phase, .waitingForExtension)
        XCTAssertEqual(tracker.repetitions.count, 0)
    }
    func testInvalidTimestampDoesNotReusePreviousObservationIndex() {
        var selector = PoseSubjectSelector()
        selector.process(frame([person(x: 0.9), person(x: 0.48)], 1))
        let empty = frame([], 1)
        XCTAssertNil(selector.process(empty).index)
        XCTAssertTrue(selector.process(empty).selectedFrame(from: empty).people.isEmpty)
    }
    func testReturningEndpointCanBeLowerThanAcquisitionOnlyAfterObservedPeak() throws {
        var v3 = PoseRuntimePolicy.standard
        v3.curlRecovery = nil; v3.eccentricPolicy = nil
        var tracker = CurlTracker(side: .left, runtimePolicy: v3)
        let angles = [160.0,160,160,160,160,125,110,90,55,55,55,55,55,80,100,120,140,140,140,140,140]
        for (i, a) in angles.enumerated() { tracker.process(curl(a, Double(i) / 10)) }
        XCTAssertEqual(tracker.repetitions.count, 1)
        var settings = PoseSessionSettings(configuration: .standard, runtimePolicy: .standard)
        settings.configuration.curl.departureAngleDegrees = 140
        XCTAssertThrowsError(try settings.validate())
        tracker.interrupt()
        for i in 22...30 { tracker.process(curl(140, Double(i) / 10)) }
        XCTAssertEqual(tracker.snapshot.phase, .waitingForExtension)
        XCTAssertEqual(tracker.repetitions.count, 1)
    }
    func testValidLegacyCustomProfileMigratesWithoutPreconditionCrashOrOverwritingAngles() throws {
        var configuration = PoseCounterConfiguration.standard
        configuration.curl.loweredAngleDegrees = 140
        try configuration.validate()
        let settings = try PoseSessionSettings.migrating(configuration: configuration)
        XCTAssertEqual(settings.configuration, configuration)
        XCTAssertEqual(settings.runtimePolicy.endpointToleranceDegrees, 0)
        XCTAssertEqual(settings.runtimePolicy.curlReturnToleranceDegrees, 0)
        _ = CurlTracker(side: .left, configuration: settings.configuration, runtimePolicy: settings.runtimePolicy)
    }
    func testV3NeverCountsStaticTopHalfRangeOrSinglePeakSpike() {
        for angles in [Array(repeating: 55.0, count: 40),
                       [160,160,160,160,160,140,120,100,95,95,95,95,100,120,140,160,160,160,160],
                       [160,160,160,160,160,135,120,55,120,160,160,160,160]] {
            var tracker = CurlTracker(side: .left, runtimePolicy: .standard)
            for (i, a) in angles.enumerated() { tracker.process(curl(a, Double(i)/10)) }
            XCTAssertEqual(tracker.repetitions.count, 0)
        }
    }
}
