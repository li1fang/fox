import Foundation
import XCTest
@testable import FoxTrainingCore

final class TrainingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func plan(sets: Int = 2, duration: Double? = nil) -> TrainingPlan {
        TrainingPlan(focus: "测试", exercises: [Exercise(name: "哑铃弯举", sets: (1...sets).map {
            SetTarget(setIndex: $0, reps: 10, duration: duration, weight: 2.5, rest: 30)
        })])
    }
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fox-test-\(UUID())/records.json")
    }

    func testFullLoopPersistsConfirmedRecordWithoutAService() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = try LocalTrainingRepository(fileURL: url)
        try repository.start(plan: plan(), at: start)
        for index in 0..<2 {
            let now = start.addingTimeInterval(Double(index * 100))
            if index > 0 { try repository.updateCurrent { try $0.readyAfterRest(at: now) } }
            try repository.updateCurrent { try $0.startSet(at: now) }
            try repository.updateCurrent { try $0.finishSet(at: now.addingTimeInterval(12)) }
            try repository.updateCurrent { try $0.submit(reps: 10, feedback: [.comfortable, .notFollowed], notes: "慢一些", at: now.addingTimeInterval(20)) }
        }
        XCTAssertEqual(repository.archive.currentSession?.stage, .summary)
        try repository.updateCurrent { try $0.confirm(note: "已核对", at: start.addingTimeInterval(160)) }
        let reloaded = try LocalTrainingRepository(fileURL: url)
        XCTAssertNil(reloaded.archive.currentSession)
        let session = try XCTUnwrap(reloaded.archive.sessions.last)
        XCTAssertEqual(session.stage, .confirmed)
        XCTAssertEqual(session.records.count, 2)
        XCTAssertEqual(session.records.map(\.durationSeconds), [12, 12])
        XCTAssertEqual(session.records[0].feedback.count, 2)
        XCTAssertEqual(session.records[0].countingMethod, "manual")
        XCTAssertThrowsError(try repository.start(plan: TrainingPlan(focus: "空", exercises: []), at: start))
    }

    func testPausedTimeAndFeedbackTimeAreNotExerciseTime() throws {
        var session = try TrainingSession(plan: plan(), now: start)
        try session.startSet(at: start)
        try session.pause(at: start.addingTimeInterval(12))
        XCTAssertEqual(session.elapsed(at: start.addingTimeInterval(60)), 12)
        try session.startSet(at: start.addingTimeInterval(100))
        try session.finishSet(at: start.addingTimeInterval(108))
        try session.submit(reps: 8, feedback: [.tooHard], notes: "", at: start.addingTimeInterval(140))
        XCTAssertEqual(session.records[0].durationSeconds, 20)
        XCTAssertEqual(session.records[0].endedAt, start.addingTimeInterval(108))
        XCTAssertEqual(session.restRemaining(at: start.addingTimeInterval(150)), 20)
        XCTAssertEqual(session.restRemaining(at: start.addingTimeInterval(400)), 0)
        try session.extendRest(by: 30, at: start.addingTimeInterval(400))
        XCTAssertEqual(session.restRemaining(at: start.addingTimeInterval(400)), 30)
    }

    func testRestartRecoversOnlyObservedActiveTimeAndRequiresResume() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = try LocalTrainingRepository(fileURL: url)
        try repository.start(plan: plan(), at: start)
        try repository.updateCurrent { try $0.startSet(at: start) }
        try repository.updateCurrent { $0.checkpoint(at: start.addingTimeInterval(15)) }
        let restored = try LocalTrainingRepository(fileURL: url)
        XCTAssertEqual(restored.archive.currentSession?.stage, .paused)
        XCTAssertEqual(restored.archive.currentSession?.elapsed(at: start.addingTimeInterval(1000)), 15)
    }

    func testWeightCarriesAcrossEqualTargetsButNewMovementUsesItsTarget() throws {
        var configured = plan()
        configured.exercises.append(Exercise(name: "侧平举", sets: [SetTarget(setIndex: 1, weight: 2.5)]))
        var session = try TrainingSession(plan: configured, now: start)
        try session.setWeight(5)
        for index in 0..<2 {
            if index > 0 { try session.readyAfterRest(at: start) }
            try session.startSet(at: start)
            try session.finishSet(at: start.addingTimeInterval(10))
            try session.submit(reps: 10, feedback: [], notes: "", at: start.addingTimeInterval(10))
            XCTAssertEqual(session.currentWeight, index == 0 ? 5 : 2.5)
        }
        XCTAssertEqual(session.records.map(\.weight), [5, 5])
    }

    func testSkipEarlyEndAndPainKeepHonestRecords() throws {
        var session = try TrainingSession(plan: plan(), now: start)
        try session.skip(at: start)
        XCTAssertEqual(session.records.first?.status, "skipped")
        XCTAssertNil(session.records.first?.reps)
        try session.readyAfterRest(at: start)
        try session.startSet(at: start)
        try session.endEarly(at: start.addingTimeInterval(8))
        XCTAssertEqual(session.stage, .summary)
        XCTAssertEqual(session.records.last?.durationSeconds, 8)
        XCTAssertNil(session.records.last?.reps)
        XCTAssertTrue(session.endedEarly)
        var pain = try TrainingSession(plan: plan(), now: start)
        try pain.startSet(at: start)
        try pain.finishSet(at: start.addingTimeInterval(3))
        try pain.submit(reps: 2, feedback: [.pain], notes: "", at: start.addingTimeInterval(5))
        XCTAssertEqual(pain.stage, .summary)
        XCTAssertEqual(pain.records.last?.status, "partial")
    }

    func testWeightIsNotCarriedBetweenDifferentUnitsOrIntoBodyweight() throws {
        var configured = plan(sets: 3)
        configured.exercises[0].targetSets[1].weightUnit = "lb"
        configured.exercises[0].targetSets[2].weightUnit = "bodyweight"
        var session = try TrainingSession(plan: configured, now: start)
        try session.setWeight(5)
        try session.startSet(at: start)
        try session.finishSet(at: start)
        try session.submit(reps: 10, feedback: [], notes: "", at: start)
        XCTAssertEqual(session.currentWeight, 2.5)
        try session.readyAfterRest(at: start)
        try session.startSet(at: start)
        try session.finishSet(at: start)
        try session.submit(reps: 10, feedback: [], notes: "", at: start)
        XCTAssertNil(session.currentWeight)
        try session.readyAfterRest(at: start)
        XCTAssertThrowsError(try session.setWeight(5))
    }

    func testInvalidTransitionsAndDuplicateConfirmationDoNotAppendRecords() throws {
        var session = try TrainingSession(plan: plan(sets: 1), now: start)
        XCTAssertThrowsError(try session.finishSet(at: start))
        try session.startSet(at: start)
        try session.finishSet(at: start)
        XCTAssertThrowsError(try session.submit(reps: nil, feedback: [], notes: "", at: start))
        try session.submit(reps: 0, feedback: [.tooHard], notes: "", at: start)
        XCTAssertThrowsError(try session.submit(reps: 10, feedback: [], notes: "", at: start))
        try session.confirm(note: "", at: start)
        XCTAssertThrowsError(try session.confirm(note: "", at: start))
        XCTAssertThrowsError(try session.startSet(at: start))
        XCTAssertEqual(session.records.count, 1)
    }

    func testTimedSetAndSummaryCorrectionKeepMeasuredDuration() throws {
        var timed = try TrainingSession(plan: plan(sets: 1, duration: 30), now: start)
        try timed.startSet(at: start)
        try timed.finishSet(at: start.addingTimeInterval(32))
        try timed.submit(reps: nil, feedback: [], notes: "", at: start.addingTimeInterval(40))
        XCTAssertNil(timed.records[0].reps)
        XCTAssertEqual(timed.records[0].durationSeconds, 32)
        try timed.reviseRecord(id: timed.records[0].id, reps: nil, weight: 5, notes: "已核对")
        XCTAssertEqual(timed.records[0].durationSeconds, 32)
        var reps = try TrainingSession(plan: plan(sets: 1), now: start)
        try reps.startSet(at: start)
        try reps.finishSet(at: start.addingTimeInterval(12))
        try reps.submit(reps: 8, feedback: [], notes: "", at: start.addingTimeInterval(20))
        try reps.reviseRecord(id: reps.records[0].id, reps: 10, weight: 5, notes: "更正")
        XCTAssertEqual(reps.records[0].status, "completed")
        XCTAssertEqual(reps.records[0].reps, 10)
        XCTAssertEqual(reps.records[0].durationSeconds, 12)
        try reps.confirm(note: "", at: start)
        XCTAssertThrowsError(try reps.reviseRecord(id: reps.records[0].id, reps: 11, weight: 5, notes: ""))
    }

    func testSingleSideTimedTargetDoesNotRequireInventedRepetitions() throws {
        var target = plan(sets: 1, duration: 30)
        target.exercises[0].repetitionBasis = .perSide
        target.exercises[0].targetSide = .right
        var session = try TrainingSession(plan: target, now: start)
        try session.startSet(at: start)
        try session.finishSet(at: start.addingTimeInterval(32))
        try session.submit(reps: nil, feedback: [], notes: "", at: start.addingTimeInterval(40))
        try session.reviseRecord(id: session.records[0].id, reps: nil, weight: nil, notes: "reviewed")
        XCTAssertEqual(session.records[0].targetSide, .right)
        XCTAssertEqual(session.records[0].status, "completed")
        XCTAssertEqual(session.records[0].durationSeconds, 32)
        XCTAssertNil(session.records[0].reps)
        XCTAssertNil(session.records[0].sideRepetitions)
    }

    func testWriteFailureDoesNotAdvanceInMemoryState() throws {
        let repository = try LocalTrainingRepository(fileURL: file(), writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try repository.start(plan: plan(), at: start))
        XCTAssertTrue(repository.archive.sessions.isEmpty)
    }

    func testCorruptFileIsNotOverwrittenAndUnknownVersionIsRejected() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("{broken".utf8)
        try invalid.write(to: url)
        XCTAssertThrowsError(try LocalTrainingRepository(fileURL: url))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        var archive = TrainingArchive()
        archive.schemaVersion = 3
        try LocalTrainingRepository.encoder().encode(archive).write(to: url)
        XCTAssertThrowsError(try LocalTrainingRepository(fileURL: url))
    }

    func testPlanImportMatchesExistingWorkoutPlanJSONAndRejectsInvalidTargets() throws {
        let json = #"{"focus":"现有计划","estimatedDurationMinutes":10,"warmup":"热身","cooldown":"放松","safetyNotes":"停止不舒服的动作","exercises":[{"exerciseId":"curl","name":"弯举","category":"pull","completedSets":[],"restSeconds":30,"tempo":[{"phase":"lift","seconds":2,"visual":"expand"}],"targetSets":[{"setIndex":1,"targetReps":10,"targetWeight":2.5,"weightUnit":"kg","restSeconds":30}]}]}"#
        var imported = try JSONDecoder().decode(TrainingPlan.self, from: Data(json.utf8))
        try imported.validate()
        imported.exercises[0].targetSets[0].targetDurationSeconds = 30
        XCTAssertThrowsError(try imported.validate())
        imported.exercises[0].targetSets[0].targetDurationSeconds = nil
        imported.exercises[0].targetSets[0].targetReps = -1
        XCTAssertThrowsError(try imported.validate())
    }
}
