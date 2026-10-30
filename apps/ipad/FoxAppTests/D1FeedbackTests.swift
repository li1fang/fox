import XCTest
import FoxTrainingCore
@testable import Fox

@MainActor
final class D1FeedbackTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_234_000)
    private func feedback(valid: Int = 0, interrupted: Bool = false, nonzero: Bool = false, arm: ArmSide = .left, at date: Date? = nil) throws -> TrainingSession {
        let start = date ?? self.start
        let settings = WorkoutObservationSettings(exercise: .curl, arm: arm, bodyView: .side)
        var exercise = Exercise(id: "curl", name: "合成弯举", sets: [SetTarget(setIndex: 1, reps: 5, weight: 2.5)])
        exercise.visualObservation = settings; exercise.repetitionBasis = .perSide
        var session = try TrainingSession(plan: TrainingPlan(focus: "合成核对", exercises: [exercise]), now: start)
        let id = try session.prepareVisual(settings: settings, configuration: .standard, runtimePolicy: .standard, source: .fixture, at: start)
        try session.beginVisual(observationId: id, at: start.addingTimeInterval(4))
        let reps: [CurlRepetition] = nonzero ? [try JSONDecoder().decode(CurlRepetition.self, from: Data(
            #"{"liftSeconds":0.8,"holdSeconds":0.4,"lowerSeconds":1.2,"completedAtSeconds":3,"minimumConfidence":0.8,"startedAtSeconds":0.4,"peakAtSeconds":1.2,"loweredAtSeconds":2.8,"eccentric":{"schema":"fox.eccentric_measurement.v1","status":"insufficientMotion"}}"#.utf8))] : []
        try session.updateVisual(binding: XCTUnwrap(session.currentSetBinding), observationId: id, repetitions: reps,
            attempts: reps.map { PoseAttemptEvent(startedAtSeconds: $0.startedAtSeconds!, endedAtSeconds: $0.completedAtSeconds, outcome: .accepted) },
            metrics: VisionMetrics(processedFrames: 40, validFrames: valid), at: start.addingTimeInterval(8))
        if interrupted { try session.pause(at: start.addingTimeInterval(9)) }
        try session.finishSet(at: start.addingTimeInterval(10))
        return session
    }

    func testUnknownZeroDoesNotPrefillFromInvalidBriefOrValidFrameTotals() throws {
        for (valid, interrupted) in [(0, false), (1, true), (40, false), (0, true)] {
            let session = try feedback(valid: valid, interrupted: interrupted)
            let draft = TrainingFeedbackInput.initialDraft(session: session, saved: nil)
            XCTAssertEqual(draft.leftReps, "", "valid=\(valid), interrupted=\(interrupted)")
            XCTAssertEqual(draft.rightReps, "")
            XCTAssertFalse(TrainingCountInput.canConfirm([draft.leftReps, draft.rightReps]))
        }
    }

    func testNonzeroPrefillsOnlyObservedSideWithoutInventingReturn() throws {
        for side: ArmSide in [.left, .right] {
            let session = try feedback(valid: 30, nonzero: true, arm: side)
            let draft = TrainingFeedbackInput.initialDraft(session: session, saved: nil)
            XCTAssertEqual(side == .left ? draft.leftReps : draft.rightReps, "1")
            XCTAssertEqual(side == .left ? draft.rightReps : draft.leftReps, "")
            let rows = ReturnIntervalSummary.make(evidence: try XCTUnwrap(session.currentVisualEvidence))
            XCTAssertEqual(rows.count, 1); XCTAssertNil(rows[0].seconds)
            XCTAssertEqual(rows[0].reason, "insufficientMotion")
        }
    }

    func testSavedExplicitZeroOverrideAndUnknownDraftWinOverAutomaticSuggestion() throws {
        let session = try feedback(valid: 30, nonzero: true)
        for value in ["0", "4", ""] {
            var saved = TrainingFeedbackDraft(); saved.leftReps = value; saved.note = "原输入"; saved.weight = 7
            XCTAssertEqual(TrainingFeedbackInput.initialDraft(session: session, saved: saved), saved)
        }
    }

    func testStoreSavesExplicitZeroAndOverrideWithOriginalEvidenceAndVersion() throws {
        for actual in [0, 4] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("D1Feedback-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("training.json")
            let session = try feedback(valid: actual == 0 ? 0 : 30, nonzero: actual != 0)
            var archive = TrainingArchive(); archive.plan = session.plan; archive.sessions = [session]
            try LocalTrainingRepository.encoder().encode(archive).write(to: file)
            let store = TrainingStore(archiveURL: file)
            let token = try XCTUnwrap(store.executionToken)
            var draft = TrainingFeedbackDraft(); draft.leftReps = String(actual)
            var state = store.clientState; state.feedback[token.attemptID!.uuidString] = draft
            store.setClientState(state, token: token)
            XCTAssertTrue(store.updateSession(token: token) {
                try $0.submit(reps: nil, sideRepetitions: .init(left: actual), feedback: [], notes: "人工核对", at: start.addingTimeInterval(11))
            }, store.errorMessage ?? "")
            let reopened = TrainingStore(archiveURL: file)
            let record = try XCTUnwrap(reopened.archive.sessions.first?.records.first)
            XCTAssertEqual(record.sideRepetitions?.left, actual); XCTAssertNil(record.sideRepetitions?.right)
            XCTAssertEqual(record.visualEvidence?.automaticCount, actual == 0 ? 0 : 1)
            XCTAssertEqual(record.countingEvidenceVersion, 1)
            XCTAssertEqual(record.countingMethod, actual == 0 ? "manual_with_visual" : "vision_corrected")
            XCTAssertEqual(record.id, token.attemptID)
            XCTAssertEqual(record.visualEvidence?.binding.sessionId, token.sessionID)
            XCTAssertEqual(reopened.archive.sessions.first?.clientState?.feedback[token.attemptID!.uuidString], draft)
            if actual != 0 {
                XCTAssertNil(ReturnIntervalSummary.make(evidence: try XCTUnwrap(record.visualEvidence))[0].seconds)
            }
        }
    }

    func testFailedConfirmationRetainsNonzeroFactsAndNotesAndRetryConfirmsOnce() throws {
        let file = try archiveFile()
        let session = try feedback(valid: 30, nonzero: true)
        var archive = TrainingArchive(); archive.plan = session.plan; archive.sessions = [session]
        try LocalTrainingRepository.encoder().encode(archive).write(to: file)
        var failNextWrite = false
        let store = TrainingStore(archiveURL: file, writer: { data, url in
            if failNextWrite { failNextWrite = false; throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let token = try XCTUnwrap(store.executionToken)
        let feeling = "这一组偏轻，下次想试15kg；不是本次重量。"
        let summary = "今日结束，明天从训练记录继续回看。"
        var draft = TrainingFeedbackDraft(); draft.leftReps = "3"; draft.note = feeling
        var state = store.clientState; state.feedback[token.attemptID!.uuidString] = draft
        state.summary = summary; store.setClientState(state, token: token)
        XCTAssertTrue(store.updateSession(token: token) {
            try $0.submit(reps: nil, sideRepetitions: .init(left: 3), feedback: [], notes: feeling,
                at: start.addingTimeInterval(11))
        }, store.errorMessage ?? "")
        let originalRecord = try XCTUnwrap(store.session?.records.first)
        let before = try Data(contentsOf: file)
        failNextWrite = true
        XCTAssertFalse(store.confirmSummary(token: token, note: summary))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.session?.stage, .summary)
        XCTAssertEqual(store.clientState.summary, summary)
        XCTAssertEqual(store.clientState.feedback[token.attemptID!.uuidString], draft)
        XCTAssertTrue(try HomeTrainingSnapshot.read(from: file).confirmed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), before)

        XCTAssertTrue(store.confirmSummary(token: token, note: summary), store.errorMessage ?? "")
        XCTAssertNil(store.errorMessage)
        let committed = try Data(contentsOf: file)
        XCTAssertFalse(store.confirmSummary(token: token, note: "迟到的重复确认"))
        XCTAssertEqual(try Data(contentsOf: file), committed)
        let reopened = TrainingStore(archiveURL: file)
        let saved = try XCTUnwrap(reopened.archive.sessions.first)
        let record = try XCTUnwrap(saved.records.first)
        XCTAssertEqual(reopened.archive.sessions.count, 1); XCTAssertEqual(saved.records.count, 1)
        XCTAssertEqual(saved.id, token.sessionID); XCTAssertEqual(record.id, token.attemptID)
        XCTAssertEqual(saved.stage, .confirmed); XCTAssertEqual(saved.summaryNote, summary)
        XCTAssertEqual(record.notes, feeling); XCTAssertEqual(record.weight, originalRecord.weight)
        XCTAssertEqual(saved.plan, session.plan)
        XCTAssertEqual(record.sideRepetitions?.left, 3); XCTAssertNil(record.sideRepetitions?.right)
        XCTAssertEqual(record.visualEvidence?.automaticCount, 1)
        XCTAssertEqual(record.countingMethod, "vision_corrected"); XCTAssertEqual(record.countingEvidenceVersion, 1)
        XCTAssertNil(ReturnIntervalSummary.make(evidence: try XCTUnwrap(record.visualEvidence)).first?.seconds)
    }

    func testCrossDayHistoryKeepsSessionAndSetNotesWithDistinctObservedAndConfirmedCounts() throws {
        let file = try archiveFile()
        var sessions: [TrainingSession] = []
        for day in 0..<2 {
            let date = start.addingTimeInterval(Double(day) * 86_400)
            var session = try feedback(valid: 30, nonzero: true, at: date)
            try session.submit(reps: nil, sideRepetitions: .init(left: day + 3), feedback: [],
                notes: "第\(day)天的组感受", at: date.addingTimeInterval(11))
            try session.confirm(note: "第\(day)天的训练总结", at: date.addingTimeInterval(12))
            sessions.append(session)
        }
        var archive = TrainingArchive(); archive.plan = sessions[0].plan; archive.sessions = sessions
        try LocalTrainingRepository.encoder().encode(archive).write(to: file)
        let original = try Data(contentsOf: file)
        for _ in 0..<2 {
            let history = try HomeTrainingSnapshot.read(from: file)
            XCTAssertNil(history.current)
            XCTAssertEqual(history.confirmed.map(\.id), sessions.reversed().map(\.id))
            XCTAssertEqual(history.sessions, sessions)
            for (day, session) in sessions.enumerated() {
                let saved = try XCTUnwrap(history.confirmed.first { $0.id == session.id })
                let record = try XCTUnwrap(saved.records.first)
                XCTAssertEqual(saved.summaryNote, "第\(day)天的训练总结")
                XCTAssertEqual(record.notes, "第\(day)天的组感受")
                XCTAssertEqual(record.sideRepetitions?.left, day + 3)
                XCTAssertEqual(record.visualEvidence?.automaticCount, 1)
                XCTAssertEqual(record.visualEvidence?.binding.sessionId, session.id)
                XCTAssertNil(ReturnIntervalSummary.make(evidence: try XCTUnwrap(record.visualEvidence)).first?.seconds)
            }
            XCTAssertEqual(try Data(contentsOf: file), original, "Reading prior-day history must not rewrite it")
        }
    }

    private func archiveFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("D1RoundTrip-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("training.json")
    }
}
