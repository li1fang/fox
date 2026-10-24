import CryptoKit
import FoxTrainingCore
import XCTest
import FoxTestSupport
@testable import Fox

@MainActor
final class VisionControllerReplayTests: XCTestCase {
    private let curlCycle = [160.0,160,160,160,160,140,120,100,80,55,55,55,55,75,100,100,120,120,140,140,160,160,160,160,160,160]
    private let raiseCycle = [10.0,10,10,10,10,25,40,55,65,70,85,85,85,85,75,65,55,45,35,25,15,10,10,10,10,10,10]

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FoxReplay-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func controller(_ exercise: VisionExercise = .curl, _ side: ArmSide = .left) throws -> (VisionLabController, VisionReplayClock) {
        let directory = try root()
        let c = VisionLabController(diagnosticRoot: directory.appendingPathComponent("diagnostics"), storageDirectory: directory)
        let clock = VisionReplayClock()
        c.enableReplay(clock: clock); c.changeExercise(exercise); c.changeArm(side)
        c.startCamera(); c.startCounting()
        return (c, clock)
    }
    private func frame(_ exercise: VisionExercise, _ side: ArmSide, _ angle: Double, _ t: Double, x: Double = 0.48) -> PoseFrame {
        let r = angle * .pi / 180, direction = side == .left ? 1.0 : -1.0
        var points = [side.joints[0]: PosePoint(x: x, y: 0.8)]
        if exercise == .curl {
            points[side.joints[1]] = PosePoint(x: x, y: 0.55)
            points[side.joints[2]] = PosePoint(x: x + direction * sin(r) * 0.22 * 720 / 1280, y: 0.55 + cos(r) * 0.22)
        } else {
            points[side.joints[1]] = PosePoint(x: x - direction * sin(r) * 0.22 * 720 / 1280, y: 0.8 - cos(r) * 0.22)
            points[side == .left ? .leftHip : .rightHip] = PosePoint(x: x, y: 0.43)
        }
        return PoseFrame(timestamp: t, width: 1280, height: 720, people: [BodyPose(points: points)])
    }
    private func send(_ frame: PoseFrame, to c: VisionLabController, clock: VisionReplayClock, delay: Double = 0) {
        clock.uptime = 1000 + frame.timestamp + delay
        c.replayFrame(CapturedPose(frame: frame, latencyMs: 1, revision: 1, cameraGeometry: nil))
    }
    private func prepare(_ c: VisionLabController, _ clock: VisionReplayClock, x: Double = 0.48, from start: Double = 0) {
        for i in 0...35 { send(frame(c.exercise, c.arm, c.exercise == .curl ? 160 : 10, start + Double(i) / 10, x: x), to: c, clock: clock) }
    }
    private func cycle(_ c: VisionLabController, _ clock: VisionReplayClock, from start: Double, missing: Set<Int> = []) {
        for (i, a) in (c.exercise == .curl ? curlCycle : raiseCycle).enumerated() {
            var f = frame(c.exercise, c.arm, a, start + Double(i) / 10)
            if missing.contains(i) { f.people[0].points[c.arm.joints[1]]?.confidence = 0.1 }
            send(f, to: c, clock: clock)
        }
    }

    func testSyntheticFixturePTSDoesNotConvertHostDelayIntoMotionLoss() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            var reference: [CurlRepetition]?
            for delayed in [false, true] {
                let (c, clock) = try controller(exercise, side)
                defer { c.stopCamera() }
                var timeline = PoseFixtureTimeline()
                let bottom = exercise == .curl ? 160.0 : 10.0
                let cycle = exercise == .curl ? curlCycle : raiseCycle
                let angles = Array(repeating: bottom, count: 36) + cycle + cycle
                var finalArrival = 0.0
                for (i, angle) in angles.enumerated() {
                    let delay = delayed ? (i >= 18 ? 2.0 : 0) + (i >= 45 ? 1.0 : 0) + (i >= 71 ? 1.0 : 0) : 0
                    let arrival = 1000 + Double(i) / 10 + delay
                    let pts = timeline.next(receivedAt: arrival)
                    clock.uptime = arrival
                    c.replayFrame(CapturedPose(frame: frame(exercise, side, angle, pts), latencyMs: 1, revision: 1, cameraGeometry: nil))
                    finalArrival = arrival
                }
                XCTAssertTrue(c.isCounting)
                XCTAssertEqual(c.automaticCount, 2, "\(exercise)/\(side), delayed=\(delayed)")
                XCTAssertEqual(c.metrics.interruptions, 0)
                XCTAssertEqual(c.observationReceivedUptime, finalArrival, "Arrival freshness must still use the host clock")
                if let reference { XCTAssertEqual(c.repetitions, reference, "Synthetic count and phase facts must be scheduling-independent") }
                else { reference = c.repetitions }
            }
        } }
    }

    func testSyntheticDeliveryCatchesUpKnownSamplesWithoutChangingMotionFacts() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            var reference: [CurlRepetition]?
            for stalled in [false, true] {
                let (c, clock) = try controller(exercise, side)
                defer { c.stopCamera() }
                var timeline = PoseFixtureTimeline(), delivered: [Double] = []
                let bottom = exercise == .curl ? 160.0 : 10.0
                let cycle = exercise == .curl ? curlCycle : raiseCycle
                let angles = Array(repeating: bottom, count: 36) + cycle + cycle
                for i in angles.indices {
                    if stalled && ((10...25).contains(i) || (46...80).contains(i)) { continue }
                    let arrival = 1000 + Double(i) / 10
                    clock.uptime = arrival
                    for timestamp in timeline.samplesDue(receivedAt: arrival) {
                        let index = Int(((timestamp - 1000) * 10).rounded())
                        XCTAssertTrue(angles.indices.contains(index))
                        guard angles.indices.contains(index) else { continue }
                        delivered.append(timestamp)
                        c.replayFrame(CapturedPose(frame: frame(exercise, side, angles[index], timestamp),
                            latencyMs: 1, revision: 1, cameraGeometry: nil))
                    }
                }
                XCTAssertEqual(delivered, angles.indices.map { 1000 + Double($0) * PoseFixtureTimeline.frameInterval })
                XCTAssertEqual(c.automaticCount, 2, "\(exercise)/\(side), stalled=\(stalled)")
                XCTAssertEqual(c.metrics.interruptions, 0)
                XCTAssertEqual(c.observationReceivedUptime, 1000 + Double(angles.count - 1) / 10)
                if let reference { XCTAssertEqual(c.repetitions, reference) }
                else { reference = c.repetitions }
            }
        } }
    }

    func testSyntheticControlBoundariesCannotConsumePreStartOrCancelledBacklog() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            let directory = try root(), clock = VisionReplayClock()
            let c = VisionLabController(diagnosticRoot: directory.appendingPathComponent("diagnostics"), storageDirectory: directory)
            c.enableReplay(clock: clock); c.changeExercise(exercise); c.changeArm(side); c.startCamera()
            defer { c.stopCamera() }
            clock.uptime = 1000; c.replayFixtureTick()
            clock.uptime = 1005; c.startCounting(); c.replayFixtureTick()
            XCTAssertTrue(c.isPreparing, "Idle backlog cannot complete a new countdown")
            XCTAssertFalse(c.isCounting)
            XCTAssertEqual(c.automaticCount, 0)
            for i in 1...5 { clock.uptime = 1005 + Double(i) / 10; c.replayFixtureTick() }
            c.pauseCounting()
            clock.uptime = 1015; c.startCounting(); c.replayFixtureTick()
            XCTAssertTrue(c.isPreparing, "Cancelled preparation cannot supply the rearmed countdown")
            XCTAssertFalse(c.isCounting)
            XCTAssertEqual(c.automaticCount, 0)
            for i in 1...30 { clock.uptime = 1015 + Double(i) / 10; c.replayFixtureTick() }
            XCTAssertTrue(c.isPreparing, "A full new preparation period is required")
            for i in 31...95 { clock.uptime = 1015 + Double(i) / 10; c.replayFixtureTick() }
            XCTAssertTrue(c.isCounting)
            XCTAssertEqual(c.automaticCount, 2)
            c.pauseCounting()
            clock.uptime = 1030; c.startCounting()
            var pausedAt: TimeInterval?
            c.onCountingUpdated = { [weak c] in
                pausedAt = c?.latest?.frame.timestamp
                c?.pauseCounting()
            }
            clock.uptime = 1040; c.replayFixtureTick()
            XCTAssertNotNil(pausedAt)
            XCTAssertFalse(c.isCounting)
            XCTAssertEqual(c.latest?.frame.timestamp, pausedAt, "A pause within delivery must discard the rest of the old batch")
            XCTAssertEqual(c.automaticCount, 2)
        } }
    }

    func testSyntheticDeliveryBoundsBacklogWithoutInventingFutureSamples() {
        var timeline = PoseFixtureTimeline()
        XCTAssertTrue(timeline.samplesDue(receivedAt: .nan).isEmpty)
        XCTAssertTrue(timeline.samplesDue(receivedAt: -.infinity).isEmpty)
        XCTAssertEqual(timeline.samplesDue(receivedAt: 1000), [1000])
        XCTAssertTrue(timeline.samplesDue(receivedAt: 1000).isEmpty)
        XCTAssertTrue(timeline.samplesDue(receivedAt: 999).isEmpty)
        var catchup: [Double] = []
        for _ in 0..<3 {
            let batch = timeline.samplesDue(receivedAt: 1012)
            XCTAssertLessThanOrEqual(batch.count, 50, "Bound work per delivery callback")
            catchup += batch
        }
        XCTAssertEqual(catchup, (1...120).map { 1000 + Double($0) * PoseFixtureTimeline.frameInterval })
        XCTAssertTrue(timeline.samplesDue(receivedAt: 1012).isEmpty)
        XCTAssertTrue(timeline.samplesDue(receivedAt: .infinity).isEmpty)
        var large = PoseFixtureTimeline()
        XCTAssertEqual(large.samplesDue(receivedAt: 1_000_000), [1_000_000])
        XCTAssertTrue(large.samplesDue(receivedAt: 1_000_000.05).isEmpty)
        XCTAssertEqual(large.samplesDue(receivedAt: 1_000_000.1), [1_000_000.1])
    }

    func testRealCaptureGapsStillDiscardIncompleteMotionCycles() throws {
        let (c, clock) = try controller()
        defer { c.stopCamera() }
        let angles = Array(repeating: 160.0, count: 36) + curlCycle + curlCycle
        for (i, angle) in angles.enumerated() {
            let gap = (i >= 45 ? 1.0 : 0) + (i >= 71 ? 1.0 : 0)
            let timestamp = 1000 + Double(i) / 10 + gap
            clock.uptime = timestamp
            c.replayFrame(CapturedPose(frame: frame(.curl, .left, angle, timestamp), latencyMs: 1, revision: 1, cameraGeometry: nil))
        }
        XCTAssertEqual(c.automaticCount, 0)
        XCTAssertGreaterThan(c.metrics.interruptions, 0)
        XCTAssertTrue(c.repetitions.isEmpty, "Actual missing capture time must not gain invented phase measurements")
    }

    func testPreparationReacquiresAfterWalkingBackWithoutAnotherTap() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            let (c, clock) = try controller(exercise, side)
            defer { c.stopCamera() }
            let bottom = exercise == .curl ? 160.0 : 10.0
            for i in 0...10 { send(frame(exercise, side, bottom, Double(i) / 10), to: c, clock: clock) }
            for i in 11...30 { send(PoseFrame(timestamp: Double(i) / 10, width: 1280, height: 720, people: []), to: c, clock: clock) }
            XCTAssertTrue(c.isPreparing)
            XCTAssertFalse(c.needsRebind, "Preparation must wait, not require another screen visit")
            for i in 31...63 {
                send(frame(exercise, side, bottom, Double(i) / 10, x: 0.2), to: c, clock: clock)
                XCTAssertFalse(c.isCounting, "Must restart the whole countdown")
            }
            send(frame(exercise, side, bottom, 6.4, x: 0.2), to: c, clock: clock)
            XCTAssertTrue(c.isCounting, "\(exercise)/\(side)")
            XCTAssertEqual(c.automaticCount, 0)
        } }
    }

    func testRebindIntentSurvivesSecondPreparationLossAndKeepsEccentricEvidence() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            let (c, clock) = try controller(exercise, side)
            defer { c.stopCamera() }
            prepare(c, clock); cycle(c, clock, from: 3.6)
            let first = try XCTUnwrap(c.repetitions.first)
            XCTAssertNotNil(first.eccentric)
            for i in 64...80 { send(PoseFrame(timestamp: Double(i) / 10, width: 1280, height: 720, people: []), to: c, clock: clock) }
            XCTAssertTrue(c.needsRebind)
            c.rebindSubject()
            let bottom = exercise == .curl ? 160.0 : 10.0
            for i in 81...90 { send(frame(exercise, side, bottom, Double(i) / 10), to: c, clock: clock) }
            for i in 91...110 { send(PoseFrame(timestamp: Double(i) / 10, width: 1280, height: 720, people: []), to: c, clock: clock) }
            XCTAssertFalse(c.needsRebind)
            prepare(c, clock, from: 11.1)
            XCTAssertTrue(c.isCounting)
            XCTAssertEqual(c.repetitions, [first], "Repositioning must not rewrite prior timing or count")
            cycle(c, clock, from: 14.7)
            XCTAssertEqual(c.automaticCount, 2)
            XCTAssertEqual(c.repetitions.first, first)
        } }
    }

    func testPreparationCancellationAndCameraInterruptionRevokeIntent() throws {
        for interrupted in [false, true] {
            let (c, clock) = try controller()
            defer { c.stopCamera() }
            for i in 0...10 { send(frame(.curl, .left, 160, Double(i) / 10), to: c, clock: clock) }
            if interrupted {
                let id = try XCTUnwrap(c.replayCaptureID)
                c.camera.onState?(id, .interrupted)
                c.camera.onState?(id, .running)
            } else { c.pauseCounting() }
            prepare(c, clock, from: 1.1)
            XCTAssertFalse(c.isPreparing); XCTAssertFalse(c.isCounting)
            XCTAssertEqual(c.automaticCount, 0)
        }
    }

    func testAmbiguityDuringCountdownRequiresFreshFullCountdown() throws {
        let (c, clock) = try controller()
        defer { c.stopCamera() }
        for i in 0...28 { send(frame(.curl, .left, 160, Double(i) / 10), to: c, clock: clock) }
        var ambiguous = frame(.curl, .left, 160, 2.9)
        ambiguous.people.append(ambiguous.people[0])
        send(ambiguous, to: c, clock: clock)
        XCTAssertEqual(c.startState, .waiting)
        for i in 30...62 {
            send(frame(.curl, .left, 160, Double(i) / 10), to: c, clock: clock)
            XCTAssertFalse(c.isCounting)
        }
        send(frame(.curl, .left, 160, 6.3), to: c, clock: clock)
        XCTAssertTrue(c.isCounting)
    }

    func testFormalPreparationInterruptionCannotAutoRestartOnCameraReturn() throws {
        let directory = try root()
        let store = TrainingStore(archiveURL: directory.appendingPathComponent("training.json"), diagnosticRoot: directory.appendingPathComponent("diagnostics"))
        store.prepareDay1Draft(); store.start()
        let c = store.workoutVision.controller, clock = VisionReplayClock()
        c.enableReplay(clock: clock)
        defer { store.workoutVision.stop() }
        store.workoutVision.prepare(arm: .left)
        for i in 0...10 { send(frame(.curl, .left, 160, Double(i) / 10), to: c, clock: clock) }
        let id = try XCTUnwrap(c.replayCaptureID)
        c.camera.onState?(id, .interrupted)
        c.camera.onState?(id, .running)
        prepare(c, clock, from: 1.1)
        XCTAssertFalse(c.isCounting); XCTAssertFalse(c.isPreparing)
        XCTAssertNotEqual(store.session?.stage, .active)
        XCTAssertNil(store.session?.currentObservationId)
    }

    func testBothExercisesAndSidesThroughRealCallbacks() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            let (c, clock) = try controller(exercise, side)
            defer { c.stopCamera() }
            prepare(c, clock)
            XCTAssertTrue(c.isCounting); XCTAssertEqual(c.source, .fixture)
            cycle(c, clock, from: 3.6)
            cycle(c, clock, from: 6.4)
            XCTAssertEqual(c.automaticCount, 2, "\(exercise)/\(side)")
            c.finishCounting()
            XCTAssertTrue(c.saveReport(referenceCount: 2, notes: "controller-replay"), c.errorMessage ?? "")
            let report = try XCTUnwrap(c.lastTrial)
            XCTAssertEqual(try PoseReplay.replay(report).repetitions, report.repetitions)
            XCTAssertFalse(c.diagnosticCapture.isActive)
        } }
    }

    func testSingleUsablePersonOutsideOldAcquisitionBoxCanStart() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            let (c, clock) = try controller(exercise, side)
            defer { c.stopCamera() }
            prepare(c, clock, x: 0.2)
            XCTAssertTrue(c.isCounting, "A usable near-edge subject must not wait forever: \(exercise)/\(side)")
        } }
    }

    func testFreshFrameRequiredAtCountdownEndAndAmbiguityDoesNotStart() throws {
        let (c, clock) = try controller()
        defer { c.stopCamera() }
        for i in 0...32 { send(frame(.curl, .left, 160, Double(i) / 10), to: c, clock: clock) }
        send(PoseFrame(timestamp: 3.3, width: 1280, height: 720, people: []), to: c, clock: clock)
        XCTAssertFalse(c.isCounting)
        send(frame(.curl, .left, 160, 3.4), to: c, clock: clock)
        XCTAssertTrue(c.isCounting)
        let (other, otherClock) = try controller()
        defer { other.stopCamera() }
        for i in 0...50 {
            var f = frame(.curl, .left, 160, Double(i) / 10)
            f.people += frame(.curl, .left, 160, f.timestamp, x: 0.49).people
            send(f, to: other, clock: otherClock)
        }
        XCTAssertFalse(other.isCounting); XCTAssertEqual(other.subjectSelection.state, .ambiguous)
    }

    func testWatchdogAndOldCaptureCallbackCannotResumeOrCount() throws {
        let (c, clock) = try controller()
        defer { c.stopCamera() }
        prepare(c, clock); cycle(c, clock, from: 3.6)
        let old = try XCTUnwrap(c.replayCaptureID)
        clock.uptime += 1.1; c.replayWatchdog()
        XCTAssertFalse(c.isCounting); XCTAssertEqual(c.automaticCount, 1)
        c.stopCamera(); c.startCamera()
        let f = frame(.curl, .left, 55, 30)
        c.replayFrame(CapturedPose(frame: f, latencyMs: 1, revision: 1, cameraGeometry: nil), capture: old)
        XCTAssertNil(c.latest)
        XCTAssertEqual(c.automaticCount, 1)
    }

    func testFormalWorkoutPersistsCountsThroughProductionCoordinator() throws {
        let directory = try root()
        let store = TrainingStore(archiveURL: directory.appendingPathComponent("training.json"), diagnosticRoot: directory.appendingPathComponent("diagnostics"))
        store.prepareDay1Draft(); store.start()
        let c = store.workoutVision.controller, clock = VisionReplayClock()
        c.enableReplay(clock: clock)
        defer { store.workoutVision.stop() }
        store.workoutVision.prepare(arm: .left)
        prepare(c, clock); cycle(c, clock, from: 3.6)
        XCTAssertEqual(store.session?.stage, .active, store.errorMessage ?? "")
        XCTAssertEqual(store.session?.currentVisualEvidence?.automaticCount, 1, store.errorMessage ?? "")
        XCTAssertEqual(store.session?.currentVisualEvidence?.source, .fixture)
        XCTAssertTrue(store.workoutVision.pause(), store.errorMessage ?? "")
        XCTAssertEqual(store.session?.stage, .paused)
        XCTAssertEqual(store.session?.currentVisualEvidence?.automaticCount, 1)
    }

    func testShortFlickerDoesNotEraseCycleButMissingPeakCannotInventOne() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            let (c, clock) = try controller(exercise, side)
            defer { c.stopCamera() }
            prepare(c, clock)
            cycle(c, clock, from: 3.6, missing: [16])
            XCTAssertEqual(c.automaticCount, 1, "short flicker: \(exercise)/\(side)")
            cycle(c, clock, from: 6.4, missing: Set(8...14))
            XCTAssertEqual(c.automaticCount, 1, "unseen peak must not count")
            cycle(c, clock, from: 9.2)
            XCTAssertEqual(c.automaticCount, 2, "next full cycle must recover")
        } }
    }

    func testLongSubjectLossRebindRetainsCountsWithoutBridgingHalfCycle() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            let (c, clock) = try controller(exercise, side)
            defer { c.stopCamera() }
            prepare(c, clock); cycle(c, clock, from: 3.6)
            for i in 0...9 { send(frame(exercise, side, exercise == .curl ? 55 : 85, 6.4 + Double(i) / 10), to: c, clock: clock) }
            for i in 0...15 { send(PoseFrame(timestamp: 7.4 + Double(i) / 10, width: 1280, height: 720, people: []), to: c, clock: clock) }
            XCTAssertTrue(c.needsRebind)
            send(frame(exercise, side, exercise == .curl ? 160 : 10, 9), to: c, clock: clock)
            XCTAssertEqual(c.subjectSelection.state, .lost)
            XCTAssertEqual(c.automaticCount, 1)
            c.rebindSubject(); c.rebindSubject()
            XCTAssertTrue(c.isPreparing); XCTAssertEqual(c.automaticCount, 1)
            prepare(c, clock, from: 9.1); cycle(c, clock, from: 12.7)
            XCTAssertEqual(c.automaticCount, 2)
        } }
    }

    func testFormalRebindCreatesNewSegmentAndManualFallbackKeepsAutomaticEvidence() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] {
            let directory = try root()
            let store = TrainingStore(archiveURL: directory.appendingPathComponent("training.json"), diagnosticRoot: directory.appendingPathComponent("diagnostics"))
            store.prepareDay1Draft()
            if exercise == .lateralRaise {
                // Use the same real plan, moving past its two curl sets without inventing reps.
                store.start()
                for _ in 0..<2 {
                    XCTAssertTrue(store.updateSession { try $0.skip(at: Date()) })
                    XCTAssertTrue(store.updateSession { try $0.readyAfterRest(at: Date()) })
                }
            } else { store.start() }
            let c = store.workoutVision.controller, clock = VisionReplayClock()
            c.enableReplay(clock: clock)
            defer { store.workoutVision.stop() }
            store.workoutVision.prepare(arm: .left)
            XCTAssertEqual(c.exercise, exercise)
            prepare(c, clock); cycle(c, clock, from: 3.6)
            let attempt = store.session?.currentSetAttemptId, firstSegment = store.session?.currentObservationId
            for i in 0...15 { send(PoseFrame(timestamp: 6.4 + Double(i) / 10, width: 1280, height: 720, people: []), to: c, clock: clock) }
            XCTAssertTrue(c.needsRebind)
            store.workoutVision.rebindSubject()
            let secondSegment = store.session?.currentObservationId
            XCTAssertNotEqual(secondSegment, firstSegment)
            store.workoutVision.rebindSubject()
            XCTAssertEqual(store.session?.currentObservationId, secondSegment)
            XCTAssertEqual(store.session?.currentSetAttemptId, attempt)
            for i in 80...90 { send(frame(exercise, .left, exercise == .curl ? 160 : 10, Double(i) / 10), to: c, clock: clock) }
            for i in 91...110 { send(PoseFrame(timestamp: Double(i) / 10, width: 1280, height: 720, people: []), to: c, clock: clock) }
            XCTAssertFalse(c.needsRebind)
            XCTAssertNotEqual(store.session?.stage, .active, "Preparation must not start workout elapsed time")
            prepare(c, clock, from: 11.1); cycle(c, clock, from: 14.7)
            XCTAssertEqual(store.session?.currentVisualEvidence?.automaticCount, 2, store.errorMessage ?? "")
            store.workoutVision.useManual()
            XCTAssertEqual(store.session?.stage, .active)
            XCTAssertEqual(store.session?.currentVisualEvidence?.automaticCount, 2)
            XCTAssertNotNil(store.session?.currentVisualEvidence?.fallbackReason)
        }
    }

    func testDuplicateAndReorderedFramesDoNotRefreshWatchdogOrPreview() throws {
        let (c, clock) = try controller()
        defer { c.stopCamera() }
        prepare(c, clock)
        for t in [3.5, 3.4, Double.nan] {
            clock.uptime = 1004.6
            c.replayFrame(CapturedPose(frame: frame(.curl, .left, 55, t), latencyMs: 1, revision: 1, cameraGeometry: nil))
        }
        XCTAssertEqual(c.latest?.frame.timestamp, 3.5)
        c.replayWatchdog()
        XCTAssertFalse(c.isCounting)
        XCTAssertEqual(c.automaticCount, 0)
        c.startCounting()
        send(frame(.curl, .left, 160, 3.5), to: c, clock: clock, delay: 1.2)
        XCTAssertNil(c.latest, "Clearing a preview must not make an old capture fresh")
    }

    func testBriefLossDuringShortLiftRemainsInsufficientRatherThanInventingDuration() throws {
        let (c, clock) = try controller()
        defer { c.stopCamera() }
        prepare(c, clock); cycle(c, clock, from: 3.6, missing: [7])
        XCTAssertEqual(c.automaticCount, 0)
        XCTAssertEqual(c.attempts.last?.reason, .movementTooShort)
        cycle(c, clock, from: 6.4)
        XCTAssertEqual(c.automaticCount, 1)
    }

    func testFlickerDuringSufficientlyObservedLiftAndLowerAcrossBothSides() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            let (c, clock) = try controller(exercise, side)
            defer { c.stopCamera() }
            prepare(c, clock)
            let angles = (exercise == .curl ? curlCycle : raiseCycle).flatMap { [$0, $0] }
            for (i, angle) in angles.enumerated() {
                var f = frame(exercise, side, angle, 3.6 + Double(i) / 10)
                if [15, 33].contains(i) { f.people[0].points[side.joints[1]]?.confidence = 0.1 }
                send(f, to: c, clock: clock)
            }
            XCTAssertEqual(c.automaticCount, 1, "\(exercise)/\(side): \(c.attempts)")
            XCTAssertGreaterThan(c.repetitions.first?.trackingGapSeconds ?? 0, 0)
        } }
    }

    func testMissingJointsAtLoweredEndpointAndNoFramesHaveDifferentRecovery() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            let (c, clock) = try controller(exercise, side)
            defer { c.stopCamera() }
            prepare(c, clock); cycle(c, clock, from: 3.6)
            let lowered = exercise == .curl ? 160.0 : 10.0
            for i in 0...6 {
                var f = frame(exercise, side, lowered, 6.4 + Double(i) / 10)
                f.people[0].points[side.joints[1]]?.confidence = 0.1
                send(f, to: c, clock: clock)
            }
            XCTAssertEqual(c.snapshot.phase, .lowered)
            XCTAssertEqual(c.automaticCount, 1)
            cycle(c, clock, from: 7.1)
            XCTAssertEqual(c.automaticCount, 2)
            let next = try XCTUnwrap(c.latest?.frame.timestamp) + 0.5
            send(frame(exercise, side, lowered, next), to: c, clock: clock)
            XCTAssertEqual(c.snapshot.phase, .waitingForExtension)
            XCTAssertGreaterThan(c.diagnostics.resetCounts["frameGap"] ?? 0, 0)
            XCTAssertEqual(c.automaticCount, 2)
            cycle(c, clock, from: next + 0.1)
            XCTAssertEqual(c.automaticCount, 3)
        } }
    }

    func testImagePlaneTransformsDoNotBecomeDevicePitchGate() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] { for side in ArmSide.allCases {
            for radians in [-0.3, 0.0, 0.3] {
                let (c, clock) = try controller(exercise, side)
                defer { c.stopCamera() }
                let angles = Array(repeating: exercise == .curl ? 160.0 : 10.0, count: 36) + (exercise == .curl ? curlCycle : raiseCycle)
                for (i, a) in angles.enumerated() {
                    var f = frame(exercise, side, a, Double(i) / 10)
                    f.people[0].points = f.people[0].points.mapValues { p in
                        let x = (p.x - 0.48) * 1280, y = (p.y - 0.6) * 720
                        return PosePoint(x: 0.2 + 0.8 * (x * cos(radians) - y * sin(radians)) / 1280,
                                         y: 0.5 + 0.8 * (x * sin(radians) + y * cos(radians)) / 720, confidence: p.confidence)
                    }
                    send(f, to: c, clock: clock)
                }
                XCTAssertTrue(c.isCounting); XCTAssertEqual(c.automaticCount, 1)
                XCTAssertNil(c.devicePose, "Unknown device pitch must not be invented")
            }
        } }
    }

    func testDeliveryLatencyDoesNotChangeCapturePhaseDurations() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] {
            let (c, clock) = try controller(exercise), (delayed, delayedClock) = try controller(exercise)
            defer { c.stopCamera(); delayed.stopCamera() }
            let angles = Array(repeating: exercise == .curl ? 160.0 : 10.0, count: 36) + (exercise == .curl ? curlCycle : raiseCycle)
            for (i, angle) in angles.enumerated() {
                let f = frame(exercise, .left, angle, Double(i) / 10)
                send(f, to: c, clock: clock)
                send(f, to: delayed, clock: delayedClock, delay: 0.35 + Double(i % 2) * 0.02)
                c.replayWatchdog(); delayed.replayWatchdog()
            }
            XCTAssertEqual(c.automaticCount, 1)
            XCTAssertEqual(c.repetitions, delayed.repetitions)
        }
    }

    func testLiveSettingsUpgradeDoesNotRewriteArchivedPolicyOrCustomValues() throws {
        let directory = try root()
        var policy = PoseRuntimePolicy.standard
        policy.acquisitionMode = nil; policy.retentionSeconds = 1.7
        policy.curlRecovery = nil; policy.eccentricPolicy = nil
        let settings = PoseSessionSettings(configuration: .standard, runtimePolicy: policy)
        let url = directory.appendingPathComponent("pose-session-settings.json")
        let bytes = try JSONEncoder().encode(settings)
        try bytes.write(to: url)
        let c = VisionLabController(diagnosticRoot: directory.appendingPathComponent("diagnostics"), storageDirectory: directory)
        XCTAssertEqual(c.runtimePolicy.acquisitionMode, .singleReadyFallback)
        XCTAssertEqual(c.runtimePolicy.retentionSeconds, 1.7)
        XCTAssertNotNil(c.runtimePolicy.curlRecovery)
        XCTAssertNotNil(c.runtimePolicy.eccentricPolicy)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNil(try PoseSessionSettings.decode(bytes).runtimePolicy.acquisitionMode)
        XCTAssertNil(try PoseSessionSettings.decode(bytes).runtimePolicy.curlRecovery)
        XCTAssertNil(try PoseSessionSettings.decode(bytes).runtimePolicy.eccentricPolicy)
    }

    func testPrivateLiveCurlPackagesThroughActualController() throws {
        for (id, side, expected, hash) in [
            ("EE2A6E61-3241-4272-BE33-9DBD298D51F8", ArmSide.left, 7, "f203b235d89ceeb60a4a7232b6698f1249fd94ec746c4c668ee4f9b909facb7b"),
            ("D7C81796-A099-45EA-AE1C-B68DEF887315", .right, 6, "3f1f9ba910cd18cfd629d8837ccdb07c4042d5511b228c938f260714656df8cb")
        ] {
            let assetID = side == .left ? "curl-left" : "curl-right"
            let input = try PrivateFixtures.url("\(assetID).poses")
            let bytes = try Data(contentsOf: input)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), hash)
            let rows = try String(decoding: bytes, as: UTF8.self).split(separator: "\n").map {
                try JSONDecoder().decode(VisionDiagnosticPose.self, from: Data($0.utf8))
            }
            let events = try String(contentsOf: PrivateFixtures.url("\(assetID).events"), encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode(VisionDiagnosticEvent.self, from: Data($0.utf8))
            }
            var rebinds = events.filter { $0.kind == "prepareRequested" }.dropFirst().compactMap(\.lastCapturePTS)
            let (c, clock) = try controller(.curl, side)
            defer { c.stopCamera() }
            var origin: Double?
            for row in rows {
                if let boundary = rebinds.first, row.capturePTS > boundary {
                    c.rebindSubject(); rebinds.removeFirst()
                }
                let f = try PoseVideoRow(seconds: row.capturePTS, width: row.width, height: row.height, people: row.people).frame()
                send(f, to: c, clock: clock)
                if c.isCounting && origin == nil { origin = row.capturePTS }
                // M1 intentionally recovers the formerly stuck preparation earlier; active observations stay fixed.
                if row.isCounting {
                    XCTAssertTrue(c.isCounting)
                    XCTAssertEqual(c.subjectSelection.state.rawValue, row.subjectState, "\(side) active subject")
                    XCTAssertEqual(c.subjectSelection.index, row.selectedSubjectIndex)
                }
                if row.automaticCount > 0 { XCTAssertEqual(c.automaticCount, row.automaticCount + 1, "\(side) later event changed") }
            }
            XCTAssertEqual(c.automaticCount, expected)
            XCTAssertTrue(rebinds.isEmpty)
            if side == .right { XCTAssertEqual(c.repetitions.first?.eccentric?.status, .trackingGap) }
            let reportID = side == .left ? "BF5C6F4F-C1CA-47EA-A790-E733E227C672" : "1ACF2BA4-E5D1-46A0-A541-CCBCAD50066E"
            let baselineURL = try PrivateFixtures.url("\(assetID).baseline")
            let baseline = try LocalTrainingRepository.decoder().decode(VisionTrial.self, from: Data(contentsOf: baselineURL))
            let offset = try XCTUnwrap(rows.first(where: \.isCounting)?.capturePTS) - XCTUnwrap(origin)
            XCTAssertEqual(c.repetitions.count, baseline.repetitions.count)
            for (a, b) in zip(c.repetitions, baseline.repetitions) {
                func near(_ a: Double?, _ b: Double?, shifted: Bool = false) {
                    if let a, let b { XCTAssertEqual(a - (shifted ? offset : 0), b, accuracy: 0.000001) }
                    else { XCTAssertEqual(a, b) }
                }
                near(a.completedAtSeconds, b.completedAtSeconds, shifted: true)
                near(a.startedAtSeconds, b.startedAtSeconds, shifted: true)
                near(a.peakAtSeconds, b.peakAtSeconds, shifted: true)
                near(a.loweredAtSeconds, b.loweredAtSeconds, shifted: true)
                near(a.liftSeconds, b.liftSeconds); near(a.holdSeconds, b.holdSeconds); near(a.lowerSeconds, b.lowerSeconds)
                near(a.minimumConfidence, b.minimumConfidence); near(a.trackingGapSeconds, b.trackingGapSeconds)
                XCTAssertEqual(a.geometryFallbackFrames, b.geometryFallbackFrames)
                XCTAssertEqual(a.eccentric?.status, b.eccentric?.status)
                near(a.eccentric?.startedAtSeconds, b.eccentric?.startedAtSeconds, shifted: true)
                near(a.eccentric?.detectedAtSeconds, b.eccentric?.detectedAtSeconds, shifted: true)
                near(a.eccentric?.endedAtSeconds, b.eccentric?.endedAtSeconds, shifted: true)
                near(a.eccentric?.durationSeconds, b.eccentric?.durationSeconds)
                near(a.eccentric?.onsetUncertaintySeconds, b.eccentric?.onsetUncertaintySeconds)
            }
            c.finishCounting()
            XCTAssertTrue(c.saveReport(referenceCount: expected, notes: "R2 raw camera observations through controller; not a new live trial"), c.errorMessage ?? "")
            let report = try XCTUnwrap(c.lastTrial)
            XCTAssertEqual(try PoseReplay.replay(report).repetitions, report.repetitions)
            let attachment = XCTAttachment(data: try LocalTrainingRepository.encoder().encode(report), uniformTypeIdentifier: "public.json")
            attachment.name = "R2-live-\(side.rawValue)-controller-replay"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testPrivateM4CacheThroughActualControllerMatchesCorePerFrame() throws {
        let input = try PrivateFixtures.url("reference.cache")
        let bytes = try Data(contentsOf: input)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "84f2651a2f8b5fc1fd71c6a98e5b43f66ac8afb70ae3f8d12e6db2948af7f7f7")
        let lines = try XCTUnwrap(String(data: bytes, encoding: .utf8)).split(separator: "\n")
        let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: String]
        XCTAssertEqual(header["source"], "device-video-not-camera")
        XCTAssertEqual(header["videoSHA256"], "48b5913c45da677819ca2e18791865b624518d351ce5592e2d3a051a6fde7d66")
        let rows = try lines.dropFirst().map { try JSONDecoder().decode(PoseVideoRow.self, from: Data($0.utf8)) }
        XCTAssertEqual(rows.count, 2004)
        var receipt: [[String: Any]] = []
        for (name, exercise, side, start, end, count) in [
            ("A01-left", VisionExercise.curl, ArmSide.left, 7.0, 60.0, 9),
            ("A02-right", .curl, .right, 60.0, 107.0, 9),
            ("A03-left", .lateralRaise, .left, 120.0, 155.0, 4),
            ("A03-right", .lateralRaise, .right, 120.0, 155.0, 4)
        ] {
            let (c, clock) = try controller(exercise, side)
            defer { c.stopCamera() }
            var selector = PoseSubjectSelector(policy: c.runtimePolicy)
            var gate = PoseStartGate(lossTolerance: c.runtimePolicy.countdownLossTolerance)
            gate.arm()
            var tracker = CurlTracker(side: side, exercise: exercise, configuration: c.configuration, runtimePolicy: c.runtimePolicy)
            var began = false, events: [[String: Any]] = []
            for row in rows where row.seconds >= start && row.seconds < end {
                let f = try row.frame(), selection = selector.process(f, side: side), selected = selection.selectedFrame(from: f)
                if !began { began = gate.process(timestamp: f.timestamp, poseReady: PoseSubjectSelector.isReady(selected, side: side, confidence: c.runtimePolicy.subjectConfidence)) == .ready }
                if began { tracker.process(selected, originalPeopleCount: f.people.count, selection: selection) }
                send(f, to: c, clock: clock)
                XCTAssertEqual(c.subjectSelection.state, selection.state, "\(name) @\(f.timestamp)")
                XCTAssertEqual(c.subjectSelection.index, selection.index)
                XCTAssertEqual(c.isCounting, began)
                XCTAssertEqual(c.automaticCount, tracker.repetitions.count, "\(name) @\(f.timestamp)")
                if began { XCTAssertEqual(c.snapshot.phase, tracker.snapshot.phase) }
                events.append(["pts": f.timestamp, "subject": c.subjectSelection.state.rawValue,
                    "index": c.subjectSelection.index as Any? ?? NSNull(), "preparing": c.isPreparing,
                    "counting": c.isCounting, "phase": c.snapshot.phase.rawValue, "count": c.automaticCount])
            }
            XCTAssertEqual(c.automaticCount, count, name)
            XCTAssertEqual(c.repetitions, tracker.repetitions)
            receipt.append(["case": name, "count": c.automaticCount, "events": events])
        }
        let output: [String: Any] = ["source": "M4-offline-cache-through-app-controller-not-live-camera",
            "sha256": digest, "cases": receipt]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "controller-m4-per-frame-comparison"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
