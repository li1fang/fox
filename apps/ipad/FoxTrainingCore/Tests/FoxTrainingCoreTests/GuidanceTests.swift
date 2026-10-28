import XCTest
@testable import FoxTrainingCore

final class GuidanceTests: XCTestCase {
    func testLegacyReplayInputKeepsWeightPromptWithoutNewFields() throws {
        let encoded = try JSONEncoder().encode(input(0, stage: .ready))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "requiresWeightConfirmation")
        legacy.removeValue(forKey: "plannedCycleLimit")
        let value = try JSONDecoder().decode(GuidanceInput.self, from: JSONSerialization.data(withJSONObject: legacy))
        var policy = GuidancePolicy()
        XCTAssertEqual(policy.update(value).cues.first?.text, "开始前请确认本组重量")
        XCTAssertNil(value.plannedCycleLimit)
    }

    func testReadyQuestionAndRestExpiryAreOncePerContextAndDoNotRequireASR() {
        var policy = GuidancePolicy()
        var value = input(0, stage: .ready)
        XCTAssertEqual(policy.update(value).cues.first?.text, "开始前请确认本组重量")
        value.time = 0.1
        XCTAssertTrue(policy.update(value).cues.isEmpty)
        value.stage = .rest; value.time = 1; value.restRemainingSeconds = 0.5
        XCTAssertEqual(policy.update(value).cues.first?.text, "休息一下，准备好后再继续")
        value.time = 1.6; value.restRemainingSeconds = 0
        XCTAssertEqual(policy.update(value).cues.first?.text, "休息时间到了，要再休息一会儿吗")
        value.time = 1.7
        XCTAssertTrue(policy.update(value).cues.isEmpty)
        value.time = 2; value.restRemainingSeconds = 30
        XCTAssertTrue(policy.update(value).cues.isEmpty)
        value.time = 32; value.restRemainingSeconds = 0
        XCTAssertNotNil(policy.update(value).cues.first)
    }
    private let tempo = [TempoPhase("lift", seconds: 2, visual: "expand"),
                         TempoPhase("peak", seconds: 1, visual: "pulse"),
                         TempoPhase("lower", seconds: 3, visual: "contract")]

    func testTempoExtractedWithoutChangingExistingValidAnimation() {
        for tick in 0..<1200 {
            let elapsed = Double(tick) / 30
            let p = elapsed.truncatingRemainder(dividingBy: 6)
            let value = TempoTimeline.sample(tempo, elapsed: elapsed)
            let expected = p < 2 ? 0.65 + p / 2 * 0.35 :
                p < 3 ? 1 + sin((p - 2) * .pi * 8) * 0.025 : 1 - (p - 3) / 3 * 0.35
            XCTAssertEqual(value.scale, expected, accuracy: 1e-10)
            XCTAssertEqual(value.phase, p < 2 ? "lift" : p < 3 ? "peak" : "lower")
        }
        XCTAssertFalse(TempoTimeline.sample(tempo, elapsed: .nan).isValid)
        XCTAssertFalse(TempoTimeline.sample(tempo, elapsed: -1).isValid)
        XCTAssertFalse(TempoTimeline.sample([], elapsed: 0).isValid)
        XCTAssertFalse(TempoTimeline.sample([.init("lift", seconds: 0, visual: "")], elapsed: 0).isValid)
        XCTAssertEqual(TempoTimeline.sample(tempo, elapsed: 6).cycle, 1)
    }

    private func input(_ time: Double, count: Int = 0, phase: CurlPhase = .lowered,
                       quality: PoseQuality = .valid, tracking: PoseTrackingState = .tracking,
                       stage: GuidanceStage = .active, exercise: VisionExercise = .curl,
                       attempt: String = "attempt", observedAt: Double? = nil) -> GuidanceInput {
        var snapshot = CurlSnapshot()
        snapshot.phase = phase; snapshot.quality = quality; snapshot.trackingState = tracking
        return GuidanceInput(context: .init(sessionID: "session", attemptID: attempt, observationID: "observation"),
            time: time, stage: stage, exercise: exercise, mode: .observed, count: count, targetReps: 5,
            motion: .init(observedAt: observedAt ?? time, snapshot: snapshot), tempo: tempo, elapsed: time)
    }

    func testCountsOnlyNewCommittedFactsAndDoesNotReannounceRestoredHistory() {
        var policy = GuidancePolicy()
        XCTAssertFalse(policy.update(input(0, count: 3)).cues.contains { $0.kind == .count })
        let next = policy.update(input(1, count: 4))
        XCTAssertEqual(next.cues.filter { $0.kind == .count }.map(\.text), ["4，还有最后一个"])
        XCTAssertFalse(policy.update(input(1.1, count: 4)).cues.contains { $0.kind == .count })
        XCTAssertEqual(policy.update(input(2, count: 5)).cues.first?.text, "5，目标次数已完成")
        XCTAssertEqual(policy.update(input(3, count: 6)).cues.first?.text, "6")
        XCTAssertFalse(policy.update(input(4, count: 2, attempt: "next")).cues.contains { $0.kind == .count })
    }

    func testShortGapAbstainsThenFreshStableRecoveryDoesNotRepeatReturnInstruction() {
        var policy = GuidancePolicy()
        _ = policy.update(input(0))
        XCTAssertTrue(policy.update(input(0.1, phase: .lowering)).cues.isEmpty)
        let phase = policy.update(input(0.3, phase: .lowering))
        XCTAssertEqual(phase.cues.first?.kind, .phase)
        XCTAssertEqual(phase.presentation.source, .observed)
        let gap = policy.update(input(0.4, phase: .lowering, quality: .lowConfidence, tracking: .grace))
        XCTAssertFalse(gap.presentation.isMoving)
        XCTAssertTrue(gap.cues.isEmpty)
        XCTAssertFalse(policy.update(input(0.5, phase: .lowering)).presentation.isMoving)
        let recovered = policy.update(input(0.7, phase: .lowering))
        XCTAssertTrue(recovered.presentation.isMoving)
        XCTAssertFalse(recovered.cues.contains { $0.kind == .phase })
    }

    func testOldFutureOrOutOfOrderMotionCannotDriveGuidance() {
        for observed in [-2.0, 2.0] {
            var policy = GuidancePolicy()
            let value = policy.update(input(1, phase: .lowering, observedAt: observed))
            XCTAssertFalse(value.presentation.isMoving)
            XCTAssertFalse(value.cues.contains { $0.kind == .phase })
        }
        var policy = GuidancePolicy()
        _ = policy.update(input(2))
        XCTAssertTrue(policy.update(input(1, count: 1)).cues.isEmpty)
        XCTAssertTrue(policy.update(input(.nan, count: 2)).cues.isEmpty)
    }

    func testLatPulldownUsesReturnNotLiteralLowerOrSyntheticEccentricDuration() {
        var policy = GuidancePolicy()
        _ = policy.update(input(0, exercise: .latPulldown))
        _ = policy.update(input(0.1, phase: .raising, exercise: .latPulldown))
        let peak = policy.update(input(0.4, count: 1, phase: .top, exercise: .latPulldown))
        XCTAssertEqual(peak.cues.first?.kind, .count)
        _ = policy.update(input(0.6, count: 1, phase: .lowering, exercise: .latPulldown))
        let returning = policy.update(input(0.8, count: 1, phase: .lowering, exercise: .latPulldown))
        XCTAssertEqual(returning.cues.first?.text, "返回")
        XCTAssertEqual(returning.presentation.label, "返回")
        XCTAssertFalse(returning.cues.contains { $0.text.contains("秒") })
    }

    func testObservedReturnCopyIsShortAndDoesNotClaimSpeedOrTechniqueQuality() {
        for exercise in [VisionExercise.curl, .lateralRaise, .latPulldown] {
            var policy = GuidancePolicy()
            _ = policy.update(input(0, exercise: exercise))
            _ = policy.update(input(0.1, phase: .lowering, exercise: exercise))
            let cue = policy.update(input(0.3, phase: .lowering, exercise: exercise)).cues.first
            XCTAssertEqual(cue?.text, exercise == .latPulldown ? "返回" : "放回")
            XCTAssertEqual(cue?.kind, .phase)
            XCTAssertNotNil(cue?.phaseToken)
        }
    }

    func testObservedModeNeverFallsBackToPlannedTempoAndOffStaysSilent() {
        var policy = GuidancePolicy()
        var value = input(0, quality: .noPerson, tracking: .lost)
        XCTAssertEqual(policy.update(value).presentation.source, .unavailable)
        value.time = 1; value.mode = .planned
        let planned = policy.update(value)
        XCTAssertEqual(planned.presentation.source, .planned)
        value.time = 2; value.mode = .off; value.count = 1
        let off = policy.update(value)
        XCTAssertTrue(off.cues.isEmpty)
        XCTAssertFalse(off.presentation.isMoving)
        value.time = 3; value.mode = .planned; value.tempo = []
        XCTAssertEqual(policy.update(value).presentation.source, .unavailable)
    }

    func testPrefixCausalityAndRepeatDeterminism() {
        let stream: [GuidanceInput] = (0..<80).map { i -> GuidanceInput in
            let phase: CurlPhase = i % 25 < 10 ? .raising : .lowering
            let quality: PoseQuality = i == 40 ? .lowConfidence : .valid
            return input(Double(i) / 10, count: i / 25, phase: phase, quality: quality)
        }
        var whole = GuidancePolicy()
        let outputs = stream.map { whole.update($0) }
        for end in stream.indices {
            var prefix = GuidancePolicy()
            var last: GuidanceUpdate?
            for sample in stream.prefix(end + 1) { last = prefix.update(sample) }
            XCTAssertEqual(last, outputs[end])
        }
    }

    func testQueueBoundedDeduplicatedAndCancelsStalePhaseOrWrongAttempt() throws {
        var policy = GuidancePolicy()
        _ = policy.update(input(0))
        _ = policy.update(input(0.1, phase: .lowering))
        let phase = policy.update(input(0.3, phase: .lowering))
        var queue = GuidanceQueue(capacity: 2)
        let cue = try XCTUnwrap(phase.cues.first)
        queue.enqueue(cue); queue.enqueue(cue)
        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertNil(queue.takeNext(at: 0.4, context: input(0).context, stage: .active, phaseToken: nil))
        queue.enqueue(cue)
        XCTAssertNil(queue.takeNext(at: 4, context: input(0).context, stage: .active, phaseToken: cue.phaseToken))
        let count = try XCTUnwrap(policy.update(input(0.5, count: 1)).cues.first)
        queue.enqueue(count)
        XCTAssertNil(queue.takeNext(at: 0.6, context: input(0, attempt: "other").context, stage: .active, phaseToken: nil))
        queue.enqueue(count)
        XCTAssertNil(queue.takeNext(at: 0.7, context: input(0).context, stage: .active, phaseToken: nil), "Cancelled IDs must not resurrect")
        for i in 2...8 {
            for newCue in policy.update(input(Double(i), count: i)).cues { queue.enqueue(newCue) }
        }
        XCTAssertLessThanOrEqual(queue.pending.count, 2)
    }

    func testCancelledPhaseIsNotValidJustBecauseItsDeadlineHasNotExpired() throws {
        var policy = GuidancePolicy()
        _ = policy.update(input(0))
        _ = policy.update(input(0.1, phase: .lowering))
        let output = policy.update(input(0.3, phase: .lowering))
        let cue = try XCTUnwrap(output.cues.first)
        XCTAssertTrue(cue.isValid(at: 0.35, context: input(0).context, stage: .active, phaseToken: output.presentation.phaseToken))
        let missing = policy.update(input(0.4, quality: .lowConfidence, tracking: .grace))
        XCTAssertFalse(cue.isValid(at: 0.4, context: input(0).context, stage: .active, phaseToken: missing.presentation.phaseToken))
    }

    func testCountCancelsOnPauseButStartDeadlineDoesNotCutAnAlreadyStartedCount() throws {
        var policy = GuidancePolicy()
        _ = policy.update(input(0))
        let cue = try XCTUnwrap(policy.update(input(0.1, count: 1)).cues.first)
        XCTAssertFalse(cue.isValid(at: 0.2, context: input(0).context, stage: .paused, phaseToken: nil))
        XCTAssertFalse(cue.isValid(at: 2, context: input(0).context, stage: .active, phaseToken: nil))
        XCTAssertTrue(cue.isCurrent(context: input(0).context, stage: .active, phaseToken: nil))
    }

    func testTrialDraftIsEditableUndatedAndNeverCopiesVideoWeights() throws {
        let draft = try TrainingPlan.nextTrainingTrialDraft()
        try draft.validate()
        XCTAssertNil(draft.scheduledDate)
        XCTAssertEqual(draft.exercises.compactMap { $0.visualObservation?.exercise }, [.curl, .lateralRaise, .latPulldown])
        XCTAssertTrue(draft.exercises.flatMap(\.targetSets).allSatisfy { $0.targetWeight == nil })
    }

    func testLongLossAndRecoveryAreNotRepeatedEveryFrame() {
        var policy = GuidancePolicy()
        _ = policy.update(input(0))
        _ = policy.update(input(0.2, quality: .noPerson, tracking: .lost))
        let loss = policy.update(input(1.5, quality: .noPerson, tracking: .lost)).cues.first
        XCTAssertEqual(loss?.text, "暂时看不清")
        XCTAssertEqual(loss?.isCurrent(context: input(0).context, stage: .active, phaseToken: nil, observationAvailable: false), true)
        XCTAssertEqual(loss?.isCurrent(context: input(0).context, stage: .active, phaseToken: nil, observationAvailable: true), false)
        XCTAssertTrue(policy.update(input(1.6, quality: .noPerson, tracking: .lost)).cues.isEmpty)
        _ = policy.update(input(1.7))
        XCTAssertEqual(policy.update(input(1.9)).cues.first?.text, "重新看到了")
        XCTAssertTrue(policy.update(input(2)).cues.isEmpty)
    }

    func testReturnSummaryNeverUsesLegacyLowerSecondsOrTerminalPulldownRelaxation() {
        var first = CurlRepetition(liftSeconds: 1, lowerSeconds: 9, completedAtSeconds: 2, minimumConfidence: 1)
        var second = CurlRepetition(liftSeconds: 1, completedAtSeconds: 5, minimumConfidence: 1)
        XCTAssertNil(ReturnIntervalSummary.make([first], exercise: .curl).first?.seconds)
        first.eccentric = .init(status: .trackingGap)
        XCTAssertEqual(ReturnIntervalSummary.make([first], exercise: .curl).first?.reason, "trackingGap")
        second.precedingReturn = .init(repetitionIndex: 0, measurement: .init(status: .measured,
            startedAtSeconds: 2, detectedAtSeconds: 2.2, endedAtSeconds: 3, durationSeconds: 1, onsetUncertaintySeconds: 0.1))
        let rows = ReturnIntervalSummary.make([first, second], exercise: .latPulldown)
        XCTAssertEqual(rows[0].seconds, 1)
        XCTAssertEqual(rows[0].coverage, "observed_interval_not_full_eccentric")
        XCTAssertNil(rows[1].seconds)
        XCTAssertEqual(rows[1].reason, "terminal_return_unpublished")
    }
}
