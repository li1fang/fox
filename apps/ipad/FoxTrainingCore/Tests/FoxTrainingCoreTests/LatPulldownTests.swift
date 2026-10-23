import Foundation
import XCTest
@testable import FoxTrainingCore

final class LatPulldownTests: XCTestCase {
    // Shoulder/elbow/wrist only, with the upper arm moving from overhead to beside the trunk.
    static func frame(_ angle: Double, at time: Double, side: ArmSide = .left, ordinaryCurl: Bool = false) -> PoseFrame {
        let extent = max(0, min(1, (angle - 70) / 80))
        let upperDirection = ordinaryCurl ? -.pi / 2 : (-.pi / 2 + extent * .pi * 0.65)
        let h = PosePoint(x: side == .left ? 0.4 : 0.6, y: 0.5)
        let e = PosePoint(x: h.x + cos(upperDirection) * 0.16, y: h.y + sin(upperDirection) * 0.16)
        let direction = upperDirection + .pi - angle * .pi / 180
        let w = PosePoint(x: e.x + cos(direction) * 0.16, y: e.y + sin(direction) * 0.16)
        return PoseFrame(timestamp: time, width: 1000, height: 1000,
            people: [BodyPose(points: [side.joints[0]: h, side.joints[1]: e, side.joints[2]: w])])
    }
    static let pull = [150.0,150,150,150,150,140,130,120,110,100,85,75,70,70,70,70]
    static let returning = [70.0,70,80,90,105,115,125,135,145,150,150,150,150]
    private func feed(_ angles: [Double], to tracker: inout CurlTracker, time: inout Double, missing: Set<Int> = [], ordinaryCurl: Bool = false) {
        for (index, angle) in angles.enumerated() {
            var f = Self.frame(angle, at: time, side: tracker.side, ordinaryCurl: ordinaryCurl)
            if missing.contains(index) { f.people[0].points[tracker.side.joints[2]] = nil }
            tracker.process(f); time += 0.1
        }
    }
    private func tracker(_ side: ArmSide = .left) -> CurlTracker {
        CurlTracker(side: side, exercise: .latPulldown, runtimePolicy: .standard)
    }

    func testPeakCountsImmediatelyAndTerminalReturnIsNotPublished() throws {
        for side in ArmSide.allCases {
            var t = tracker(side), time = 0.0
            feed(Self.pull, to: &t, time: &time)
            XCTAssertEqual(t.repetitions.count, 1)
            let first = try XCTUnwrap(t.repetitions.first)
            XCTAssertEqual(first.countingBasis, .contractedEndpoint)
            XCTAssertNil(first.holdSeconds); XCTAssertNil(first.lowerSeconds); XCTAssertNil(first.eccentric)
            feed(Array(repeating: 70, count: 20) + Self.returning, to: &t, time: &time)
            XCTAssertEqual(t.repetitions, [first], "A final return is not a measured eccentric fact")
            t.interrupt()
            XCTAssertEqual(t.repetitions, [first])
            XCTAssertEqual(try JSONDecoder().decode([CurlRepetition].self, from: JSONEncoder().encode(t.repetitions)), [first])
        }
    }

    func testNextPeakPublishesOnlyPreviousReturnAndAppendOnlyFacts() throws {
        var t = tracker(), time = 0.0
        feed(Self.pull, to: &t, time: &time)
        let first = try XCTUnwrap(t.repetitions.first)
        feed(Self.returning + Self.pull, to: &t, time: &time)
        XCTAssertEqual(t.repetitions.count, 2); XCTAssertEqual(t.repetitions.first, first)
        let observation = try XCTUnwrap(t.repetitions.last?.precedingReturn)
        XCTAssertEqual(observation.repetitionIndex, 0)
        XCTAssertEqual(observation.measurement.status, .measured)
        XCTAssertGreaterThan(try XCTUnwrap(observation.measurement.durationSeconds), 0)
        XCTAssertNil(t.repetitions.first?.precedingReturn)
    }

    func testShortWristGapKeepsCountButDoesNotInventReturnDuration() throws {
        var t = tracker(), time = 0.0
        feed(Self.pull, to: &t, time: &time)
        feed(Self.returning, to: &t, time: &time, missing: [5])
        feed(Self.pull, to: &t, time: &time)
        XCTAssertEqual(t.repetitions.count, 2)
        XCTAssertEqual(t.repetitions.last?.precedingReturn?.measurement.status, .trackingGap)
        XCTAssertNil(t.repetitions.last?.precedingReturn?.measurement.durationSeconds)
    }

    func testLongGapRequiresNewStartWithoutDeletingExistingPeak() {
        var t = tracker(), time = 0.0
        feed(Self.pull, to: &t, time: &time)
        feed(Array(repeating: 70, count: 20), to: &t, time: &time, missing: Set(0..<15))
        XCTAssertEqual(t.repetitions.count, 1)
        feed(Self.returning + Self.pull, to: &t, time: &time)
        XCTAssertEqual(t.repetitions.count, 2)
        XCTAssertNil(t.repetitions.last?.precedingReturn)
    }

    func testNoCountForInitialPeakPartialOrdinaryCurlOrTranslation() {
        for angles in [Array(repeating: 70.0, count: 50), Array(repeating: 150.0, count: 50),
                       [150,150,150,150,130,120,110,120,130,150,150]] {
            var t = tracker(), time = 0.0
            feed(angles, to: &t, time: &time)
            XCTAssertEqual(t.repetitions.count, 0)
        }
        var t = tracker(), time = 0.0
        feed(Self.pull + Self.returning, to: &t, time: &time, ordinaryCurl: true)
        XCTAssertEqual(t.repetitions.count, 0)
        for index in 0..<50 {
            var f = Self.frame(150, at: time)
            f.people[0].points = f.people[0].points.mapValues { PosePoint(x: $0.x, y: $0.y + Double(index) * 0.001) }
            t.process(f); time += 0.1
        }
        XCTAssertEqual(t.repetitions.count, 0)
    }

    func testWristNotRequiredToPrepareButRequiredForCounting() {
        var f = Self.frame(150, at: 0)
        f.people[0].points[.leftWrist] = nil
        XCTAssertTrue(PoseSubjectSelector.isReady(f, side: .left))
        XCTAssertEqual(PoseGeometry.inspect(f, side: .left, exercise: .latPulldown).quality, .lowConfidence)
        XCTAssertNoThrow(try WorkoutObservationSettings(exercise: .latPulldown, arm: .left, bodyView: .back).validate())
        XCTAssertThrowsError(try WorkoutObservationSettings(exercise: .latPulldown, arm: .left, bodyView: .front).validate())
    }

    func testPeakSettlingIsNotEccentricAndLaterReversalIsStillRejected() {
        for reversal in [false, true] {
            var estimator = PulldownReturnEstimator(policy: .init(), departure: 110)
            let settling = [60.0,65,70,70,70,70,68,65,62,62,65,70,80,90,100,112]
            let returning = reversal ? [115.0,120,100,115,130,140] : [115.0,120,125,130,135,140]
            for (index, angle) in (settling + returning).enumerated() { estimator.observe(angle: angle, at: Double(index) / 10) }
            let result = estimator.finish(at: 2.1)
            XCTAssertEqual(result.status, reversal ? .nonMonotonic : .measured)
            if !reversal {
                XCTAssertGreaterThanOrEqual(result.startedAtSeconds ?? 0, 1.0)
                XCTAssertGreaterThanOrEqual(result.detectedAtSeconds ?? 0, 1.5)
            }
        }
    }

    func testPersistenceRejectsFabricatedDurationsAndPreservesWorkoutFacts() throws {
        var tracker = tracker(), time = 0.0
        feed(Self.pull + Self.returning + Self.pull, to: &tracker, time: &time)
        let start = Date(timeIntervalSince1970: 1_791_234_000)
        var report = VisionTrial(startedAt: start, endedAt: start.addingTimeInterval(time), device: "synthetic", appVersion: "M3-test",
            visionRevision: 1, source: .fixture, camera: "front", arm: .left, repetitions: tracker.repetitions,
            manualAdjustment: 0, referenceCount: 2, metrics: VisionMetrics(processedFrames: 50, validFrames: 50),
            notes: "", exercise: .latPulldown, counterDiagnostics: tracker.diagnostics)
        XCTAssertNoThrow(try report.validate())
        let bytes = try LocalTrainingRepository.encoder().encode(report)
        XCTAssertEqual(try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: bytes), report)
        if let folder = ProcessInfo.processInfo.environment["FOX_M3_EVIDENCE_DIR"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try bytes.write(to: URL(fileURLWithPath: folder).appendingPathComponent("pulldown-trial.json"))
        }
        report.repetitions[1].lowerSeconds = 0
        XCTAssertThrowsError(try report.validate())
        report.repetitions = tracker.repetitions
        report.repetitions[1].precedingReturn?.repetitionIndex = 1
        XCTAssertThrowsError(try report.validate())

        var exercise = Exercise(id: "lat-pulldown", name: "高位下拉", sets: [SetTarget(setIndex: 1, reps: 2, rest: 30)])
        let settings = WorkoutObservationSettings(exercise: .latPulldown, arm: .left, bodyView: .back)
        exercise.visualObservation = settings
        exercise.repetitionBasis = .total
        var session = try TrainingSession(plan: TrainingPlan(focus: "M3-test", exercises: [exercise]), now: start)
        let id = try session.prepareVisual(settings: settings, configuration: .standard, runtimePolicy: .standard, source: .fixture, at: start)
        try session.beginVisual(observationId: id, at: start)
        try session.updateVisual(binding: XCTUnwrap(session.currentSetBinding), observationId: id,
            repetitions: tracker.repetitions, attempts: tracker.attempts, metrics: VisionMetrics(processedFrames: 50, validFrames: 50),
            at: start.addingTimeInterval(time))
        try session.finishSet(at: start.addingTimeInterval(time + 1))
        try session.submit(reps: 2, feedback: [], notes: "", at: start.addingTimeInterval(time + 2))
        let evidence = try XCTUnwrap(session.records.first?.visualEvidence)
        XCTAssertEqual(evidence.automaticCount, 2)
        try evidence.validate()
        if let folder = ProcessInfo.processInfo.environment["FOX_M3_EVIDENCE_DIR"] {
            try LocalTrainingRepository.encoder().encode(evidence).write(to: URL(fileURLWithPath: folder).appendingPathComponent("pulldown-workout.json"))
        }
        let assessment = WorkoutRhythmAssessment.assess(repetitions: tracker.repetitions, tempo: [TempoPhase("lower", seconds: 2, visual: "contract")])
        XCTAssertEqual(assessment.phases.filter { $0.phase == "lower" }.map(\.repetitionIndex), [1])
        let partialReturn = try XCTUnwrap(assessment.phases.first { $0.phase == "lower" })
        XCTAssertEqual(partialReturn.status, .estimated)
        XCTAssertNil(partialReturn.deltaSeconds, "A gate-to-gate interval is not a full eccentric target comparison")
    }

    func testDuplicateFramesAndMissingPeakCannotCount() {
        var t = tracker(), time = 0.0
        feed(Self.pull, to: &t, time: &time, missing: Set(10...15))
        XCTAssertTrue(t.repetitions.isEmpty)
        let frozen = t.snapshot.phase
        t.process(Self.frame(70, at: time - 0.2))
        XCTAssertEqual(t.snapshot.phase, frozen)
        feed(Self.returning + Self.pull, to: &t, time: &time)
        XCTAssertEqual(t.repetitions.count, 1)
    }

    func testSmallSettlingReversalDoesNotIncludeHeldPeakInReturn() {
        var estimator = PulldownReturnEstimator(policy: .init(), departure: 110)
        let angles = [65.0,70,73,73,72,70,68,68,69,69,69,69,69,69,69,73,79,90,100,112,120,135,140]
        for (index, angle) in angles.enumerated() { estimator.observe(angle: angle, at: Double(index) / 10) }
        let result = estimator.finish(at: 2.2)
        XCTAssertEqual(result.status, .measured)
        XCTAssertGreaterThanOrEqual(result.startedAtSeconds ?? 0, 1.5)
    }

    func testOldRuntimeToleranceDoesNotValidateAgainstUnusedPulldownGate() {
        var configuration = PoseCounterConfiguration.standard
        configuration.latPulldown = nil
        // Keep the old lateral policy valid at 15 degrees; only the unused pulldown gate would reject it.
        configuration.lateralRaise.departureAngleDegrees = 40
        var policy = PoseRuntimePolicy.standard
        policy.endpointToleranceDegrees = 15
        policy.curlReturnToleranceDegrees = 0
        policy.curlRecovery?.initialEndpointToleranceDegrees = 0
        XCTAssertNoThrow(try PoseSessionSettings(configuration: configuration, runtimePolicy: policy).validate())
    }
}
