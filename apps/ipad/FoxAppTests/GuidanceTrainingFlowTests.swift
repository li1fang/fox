import FoxTrainingCore
import XCTest
@testable import Fox

@MainActor
final class GuidanceTrainingFlowTests: XCTestCase {
    private final class Driver: SpeechOutputDriver {
        var onEvent: ((String, SpeechPlaybackEvent) -> Void)?
        var cues: [GuidanceCue] = []
        func speak(_ cue: GuidanceCue) -> Bool {
            cues.append(cue); onEvent?(cue.id, .started); onEvent?(cue.id, .finished); return true
        }
        func stop() {}
    }

    func testThreeActionsWithGuidanceConfirmPersistAndReopenWithoutChangingMotionFacts() async throws {
        var results: [[[CurlRepetition]]] = []
        for enabled in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuidedFlow-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("training.json")
            let store = TrainingStore(archiveURL: file, diagnosticRoot: root.appendingPathComponent("diagnostics"))
            store.prepareNextTrialDraft()
            var plan = store.archive.plan
            for i in plan.exercises.indices {
                plan.exercises[i].targetSets = [SetTarget(setIndex: 1, reps: 2, rest: 30)]
            }
            store.savePlan(plan); store.start()
            let c = store.workoutVision.controller, clock = VisionReplayClock(), driver = Driver()
            c.enableReplay(clock: clock)
            let guidance = GuidanceSession(vision: c, store: store, driver: driver, defaults: nil)
            guidance.setSpeech(enabled)
            var time = 0.0
            func feed(_ values: [Double], exercise: VisionExercise, side: ArmSide) {
                for angle in values {
                    clock.uptime = 1000 + time
                    c.replayFrame(CapturedPose(frame: frame(exercise, side: side, angle: angle, time: time), latencyMs: 1, revision: 1))
                    guidance.sample(); time += 0.1
                }
            }
            for index in 0..<3 {
                let settings = try XCTUnwrap(store.session?.exercise.visualObservation)
                let exercise = settings.exercise, side = settings.arm
                let before = try XCTUnwrap(store.session)
                XCTAssertTrue(store.updateSession { try $0.setWeight(5); try $0.confirmCurrentWeight(binding: XCTUnwrap(before.currentSetBinding), at: c.wallTime) })
                guidance.sample()
                store.workoutVision.prepare(arm: side)
                feed(Array(repeating: exercise == .lateralRaise ? 10 : exercise == .curl ? 160 : 150, count: 36), exercise: exercise, side: side)
                XCTAssertEqual(store.session?.stage, .active, store.errorMessage ?? "")
                let curl = [160.0,160,160,160,160,140,120,100,80,55,55,55,55,75,100,100,120,120,140,140,160,160,160,160,160,160]
                let raise = [10.0,10,10,10,10,25,40,55,65,70,85,85,85,85,75,65,55,45,35,25,15,10,10,10,10,10,10]
                let pull = [150.0,150,150,150,150,140,130,120,110,100,85,75,70,70,70,70]
                let returning = [70.0,70,80,90,105,115,125,135,145,150,150,150,150]
                let values = exercise == .curl ? curl + curl : exercise == .lateralRaise ? raise + raise : pull + returning + pull
                feed(values, exercise: exercise, side: side)
                XCTAssertEqual(store.session?.currentVisualEvidence?.automaticCount, 2, "\(exercise): \(store.errorMessage ?? "")")
                store.workoutVision.finish(); clock.uptime += 0.1; guidance.sample()
                XCTAssertEqual(store.session?.stage, .feedback)
                let evidence = try XCTUnwrap(store.session?.currentVisualEvidence)
                let intervalRows = ReturnIntervalSummary.make(evidence: evidence)
                XCTAssertEqual(intervalRows.count, 2)
                if exercise == .latPulldown {
                    XCTAssertNil(intervalRows.last?.seconds)
                    XCTAssertEqual(intervalRows.last?.reason, "terminal_return_unpublished")
                }
                let review = try TrialReview.make(information: "5 kg", softwareIssue: "test-only feedback", trainingFeeling: "comfortable", at: c.wallTime)
                let perSide = store.session?.exercise.repetitionBasis == .perSide
                let sides = perSide ? SideRepetitions(left: side == .left ? 2 : nil, right: side == .right ? 2 : nil) : nil
                XCTAssertTrue(store.updateSession { try $0.submit(reps: perSide ? nil : 2, sideRepetitions: sides,
                    feedback: [], notes: "", at: c.wallTime, review: review) }, store.errorMessage ?? "")
                clock.uptime += 0.1; guidance.sample()
                if index < 2 {
                    XCTAssertEqual(store.session?.stage, .rest)
                    let old = try XCTUnwrap(store.session?.restDeadline)
                    XCTAssertTrue(store.updateSession { try $0.extendRest(by: 30, at: c.wallTime) })
                    XCTAssertEqual(store.session?.restDeadline, old.addingTimeInterval(30))
                    XCTAssertTrue(store.updateSession { try $0.readyAfterRest(at: c.wallTime) })
                }
                // Allow the real recorder queue to seal its synthetic, silent clip before the next attempt.
                for _ in 0..<100 {
                    if !c.diagnosticCapture.isActive { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                time += 1
            }
            XCTAssertEqual(store.session?.stage, .summary)
            XCTAssertTrue(store.updateSession { try $0.confirm(note: "integration test only", at: c.wallTime) })
            guidance.stop(); store.workoutVision.stop()
            let reopened = TrainingStore(archiveURL: file, diagnosticRoot: root.appendingPathComponent("diagnostics"))
            let saved = try XCTUnwrap(reopened.archive.sessions.last)
            XCTAssertEqual(saved.stage, .confirmed)
            XCTAssertEqual(saved.records.count, 3)
            XCTAssertTrue(saved.records.allSatisfy { $0.weight == 5 && $0.trialReview?.softwareIssue == "test-only feedback" })
            results.append(saved.records.map { $0.visualEvidence?.segments.flatMap(\.repetitions) ?? [] })
            XCTAssertEqual(driver.cues.filter { $0.kind == .count }.count, enabled ? 6 : 0)
            let exported = try XCTUnwrap(reopened.export(saved))
            defer { try? FileManager.default.removeItem(at: exported) }
            struct Export: Decodable { var session: TrainingSession }
            XCTAssertEqual(try LocalTrainingRepository.decoder().decode(Export.self, from: Data(contentsOf: exported)).session, saved)
        }
        XCTAssertEqual(results[0], results[1], "Speech enabled/disabled must preserve every repetition and return fact")
    }

    private func frame(_ exercise: VisionExercise, side: ArmSide, angle: Double, time: Double) -> PoseFrame {
        let r = angle * .pi / 180
        if exercise == .latPulldown {
            let direction = -.pi / 2 + max(0, min(1, (angle - 70) / 80)) * .pi * 0.65
            let shoulder = PosePoint(x: 0.4, y: 0.5)
            let elbow = PosePoint(x: shoulder.x + cos(direction) * 0.16, y: shoulder.y + sin(direction) * 0.16)
            let wrist = PosePoint(x: elbow.x + cos(direction + .pi - r) * 0.16, y: elbow.y + sin(direction + .pi - r) * 0.16)
            return PoseFrame(timestamp: time, width: 1000, height: 1000,
                people: [BodyPose(points: [side.joints[0]: shoulder, side.joints[1]: elbow, side.joints[2]: wrist])])
        }
        let direction = side == .left ? 1.0 : -1.0
        var points = [side.joints[0]: PosePoint(x: 0.48, y: 0.8)]
        if exercise == .curl {
            points[side.joints[1]] = .init(x: 0.48, y: 0.55)
            points[side.joints[2]] = .init(x: 0.48 + direction * sin(r) * 0.22 * 720 / 1280, y: 0.55 + cos(r) * 0.22)
        } else {
            points[side.joints[1]] = .init(x: 0.48 - direction * sin(r) * 0.22 * 720 / 1280, y: 0.8 - cos(r) * 0.22)
            points[side == .left ? .leftHip : .rightHip] = .init(x: 0.48, y: 0.43)
        }
        return PoseFrame(timestamp: time, width: 1280, height: 720, people: [BodyPose(points: points)])
    }
}
