import XCTest
import FoxTrainingCore
@testable import Fox

@MainActor
final class GuidanceOutputTests: XCTestCase {
    private final class Driver: SpeechOutputDriver {
        var onEvent: ((String, SpeechPlaybackEvent) -> Void)?
        var submitted: [GuidanceCue] = []
        var stops = 0
        var available = true
        func speak(_ cue: GuidanceCue) -> Bool { submitted.append(cue); return available }
        func stop() { stops += 1 }
    }
    private func input(_ t: Double, count: Int = 0, stage: GuidanceStage = .active,
                       phase: CurlPhase = .lowered, quality: PoseQuality = .valid, attempt: String = "1") -> GuidanceInput {
        var snapshot = CurlSnapshot(); snapshot.phase = phase; snapshot.quality = quality; snapshot.trackingState = .tracking
        return .init(context: .init(sessionID: "test", attemptID: attempt, observationID: "1"), time: t,
            stage: stage, exercise: .curl, mode: .observed, count: count, targetReps: 5,
            motion: .init(observedAt: t, snapshot: snapshot), tempo: [], elapsed: t)
    }

    func testCountsAreSpokenOnceAndPauseCancelsWithoutChangingInputFacts() throws {
        let driver = Driver(); var now = 0.0
        let output = GuidanceOutputController(driver: driver, now: { now })
        output.update(input(0))
        now = 0.1; output.update(input(now, count: 1))
        XCTAssertEqual(driver.submitted.count, 1)
        let cue = try XCTUnwrap(driver.submitted.last)
        driver.onEvent?(cue.id, .started)
        now = 0.2; output.update(input(now, count: 1))
        XCTAssertEqual(driver.submitted.count, 1)
        now = 0.3; output.update(input(now, count: 1, stage: .paused))
        XCTAssertEqual(driver.stops, 1)
        XCTAssertTrue(output.events.contains { $0.cueID == cue.id && $0.state == "cancelled" })
        // An old async completion cannot finish or restart the newer lifecycle utterance.
        driver.onEvent?(cue.id, .finished)
        XCTAssertEqual(driver.submitted.count, 2)
    }

    func testMissingObservationCancelsPhaseEvenWithoutNewCameraFrames() {
        let driver = Driver(); var now = 0.0
        let output = GuidanceOutputController(driver: driver, now: { now })
        output.update(input(0))
        now = 0.1; output.update(input(now, phase: .lowering))
        now = 0.3; output.update(input(now, phase: .lowering))
        XCTAssertEqual(driver.submitted.last?.kind, .phase)
        now = 0.7; output.tick()
        XCTAssertEqual(driver.stops, 1)
        XCTAssertFalse(output.presentation.isMoving)
    }

    func testMuteAndContextChangeNeverReplayQueuedCounts() {
        let driver = Driver(); var now = 0.0
        let output = GuidanceOutputController(driver: driver, now: { now })
        output.update(input(0))
        now = 0.1; output.update(input(now, count: 1))
        now = 0.2; output.update(input(now, count: 2))
        output.setSpeechEnabled(false)
        XCTAssertEqual(driver.stops, 1)
        now = 0.3; output.update(input(now, count: 3))
        output.setSpeechEnabled(true)
        now = 0.4; output.update(input(now, count: 3))
        XCTAssertEqual(driver.submitted.count, 1)
        now = 0.5; output.update(input(now, count: 0, attempt: "2"))
        now = 0.6; output.update(input(now, count: 1, attempt: "2"))
        XCTAssertEqual(driver.submitted.count, 2)
        XCTAssertEqual(driver.submitted.last?.context.attemptID, "2")
    }

    func testLateStartIsCancelledAndDriverFailureDoesNotDisablePresentation() throws {
        let driver = Driver(); var now = 0.0
        let output = GuidanceOutputController(driver: driver, now: { now })
        output.update(input(0))
        now = 0.1; output.update(input(now, count: 1))
        let cue = try XCTUnwrap(driver.submitted.last)
        now = 2; driver.onEvent?(cue.id, .started)
        XCTAssertTrue(output.events.contains { $0.cueID == cue.id && $0.reason == "late_start" })
        driver.available = false
        now = 2.1; output.update(input(now, count: 2))
        now = 2.3; output.update(input(now, count: 2))
        XCTAssertTrue(output.presentation.isMoving)
        XCTAssertTrue(output.events.contains { $0.state == "failed" && $0.reason == "voice_unavailable" })
    }

    func testInterruptPurgesOutputAndDoesNotAutomaticallyResumeOldSpeech() {
        let driver = Driver(); var now = 0.0
        let output = GuidanceOutputController(driver: driver, now: { now })
        output.update(input(0))
        now = 0.1; output.update(input(now, count: 1))
        output.interrupt(reason: "route_changed")
        now = 0.2; output.tick()
        XCTAssertEqual(driver.submitted.count, 1)
        XCTAssertFalse(output.presentation.isMoving)
    }

    func testSystemInterruptionConsumesNewFactsSilentlyWithoutUnmutingUserPreference() {
        let driver = Driver(); var now = 0.0
        let output = GuidanceOutputController(driver: driver, now: { now })
        output.update(input(0))
        output.suspendSpeech(true)
        now = 0.1; output.update(input(now, count: 1))
        XCTAssertTrue(output.speechEnabled)
        XCTAssertTrue(driver.submitted.isEmpty)
        output.suspendSpeech(false)
        now = 0.2; output.update(input(now, count: 1))
        XCTAssertTrue(driver.submitted.isEmpty)
        now = 0.3; output.update(input(now, count: 2))
        XCTAssertEqual(driver.submitted.count, 1)
    }
}
