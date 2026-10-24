import XCTest
@testable import FoxTrainingCore

final class TrialConfirmationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func session() throws -> TrainingSession {
        try TrainingSession(plan: TrainingPlan(focus: "试用", exercises: [Exercise(name: "弯举", sets: [
            SetTarget(setIndex: 1, weight: 5), SetTarget(setIndex: 2, weight: 5)
        ])]), now: now)
    }

    func testPrefillIsNotAnActualWeightUntilExplicitConfirmation() throws {
        var value = try session()
        XCTAssertEqual(value.currentWeight, 5)
        XCTAssertNil(value.currentWeightConfirmation)
        try value.skip(at: now)
        XCTAssertNil(value.records[0].weight)
        XCTAssertNil(value.records[0].weightConfirmation)
        try value.readyAfterRest(at: now)
        try value.startSet(at: now)
        try value.endEarly(at: now.addingTimeInterval(5))
        XCTAssertNil(value.records[1].weight, "Unanswered prefill is not an observed fact")
    }

    func testConfirmationIsBoundToAttemptAndChangingWeightInvalidatesIt() throws {
        var value = try session()
        let binding = try XCTUnwrap(value.currentSetBinding)
        try value.confirmCurrentWeight(binding: binding, at: now)
        XCTAssertEqual(value.currentWeightConfirmation?.weight, 5)
        let first = value.currentWeightConfirmation
        try value.confirmCurrentWeight(binding: binding, at: now.addingTimeInterval(1))
        XCTAssertEqual(value.currentWeightConfirmation, first, "Repeated confirmation is idempotent")
        try value.setWeight(7.5)
        XCTAssertNil(value.currentWeightConfirmation)
        try value.startSet(at: now)
        try value.finishSet(at: now.addingTimeInterval(5))
        try value.submit(reps: 8, feedback: [], notes: "", at: now.addingTimeInterval(6))
        XCTAssertEqual(value.records[0].weight, 7.5)
        XCTAssertEqual(value.records[0].weightConfirmation?.source, .setReview)
        XCTAssertNil(value.currentWeightConfirmation)
        try value.readyAfterRest(at: now.addingTimeInterval(8))
        XCTAssertThrowsError(try value.confirmCurrentWeight(binding: binding, at: now.addingTimeInterval(9)))
        XCTAssertNil(value.currentWeightConfirmation)
    }

    func testReviewSeparatesCategoriesAndSurvivesSaveReopenWithoutChangingPlan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LocalTrainingRepository(fileURL: root.appendingPathComponent("records.json"))
        let plan = try session().plan
        try repository.start(plan: plan, at: now)
        let review = try XCTUnwrap(TrialReview.make(information: " 哑铃有 7.5 kg ", softwareIssue: "提示太密", trainingFeeling: "还有余力", at: now))
        try repository.updateCurrent {
            try $0.startSet(at: now); try $0.finishSet(at: now)
            try $0.submit(reps: 8, feedback: [.tooEasy], notes: "", at: now, review: review)
        }
        let reloaded = try LocalTrainingRepository(fileURL: repository.fileURL)
        XCTAssertEqual(reloaded.archive.currentSession?.records[0].trialReview, review)
        XCTAssertEqual(reloaded.archive.currentSession?.plan, plan)
        XCTAssertEqual(review.information, "哑铃有 7.5 kg")
        XCTAssertNil(try TrialReview.make(information: " ", softwareIssue: "", trainingFeeling: "", at: now))
        XCTAssertThrowsError(try TrialReview.make(information: String(repeating: "x", count: 4001), softwareIssue: "", trainingFeeling: "", at: now))
    }

    func testFailedWriteKeepsFeedbackAndDoesNotClaimConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var fail = false
        let repository = try LocalTrainingRepository(fileURL: root.appendingPathComponent("records.json"), writer: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        try repository.start(plan: session().plan, at: now)
        try repository.updateCurrent { try $0.startSet(at: now); try $0.finishSet(at: now) }
        let before = try Data(contentsOf: repository.fileURL)
        fail = true
        XCTAssertThrowsError(try repository.updateCurrent { try $0.submit(reps: 8, feedback: [], notes: "", at: now) })
        XCTAssertEqual(repository.archive.currentSession?.stage, .feedback)
        XCTAssertTrue(repository.archive.currentSession?.records.isEmpty == true)
        XCTAssertNil(repository.archive.currentSession?.currentWeightConfirmation)
        XCTAssertEqual(try Data(contentsOf: repository.fileURL), before)
    }

    func testSegmentSummaryDoesNotLinkReturnsAcrossRepositioning() {
        let first = CurlRepetition(liftSeconds: 1, completedAtSeconds: 2, minimumConfidence: 1)
        var second = CurlRepetition(liftSeconds: 1, completedAtSeconds: 5, minimumConfidence: 1)
        second.precedingReturn = .init(repetitionIndex: 0, measurement: .init(status: .measured,
            startedAtSeconds: 2, detectedAtSeconds: 2.2, endedAtSeconds: 3, durationSeconds: 1, onsetUncertaintySeconds: 0.1))
        let a = UUID(), b = UUID()
        let rows = ReturnIntervalSummary.make(segments: [(a, [first, second]), (b, [first, second])], exercise: .latPulldown)
        XCTAssertEqual(rows.map(\.repetition), [1, 2, 3, 4])
        XCTAssertEqual(rows.map(\.seconds), [1, nil, 1, nil])
        XCTAssertEqual(rows.map(\.observationID), [a, a, b, b])
        XCTAssertEqual(rows[1].reason, "terminal_return_unpublished")
        XCTAssertEqual(rows[3].reason, "terminal_return_unpublished")
    }

    func testLegacyRecordsStillDecodeAndNewConfirmationCannotDisagreeWithActualWeight() throws {
        var value = try session()
        try value.startSet(at: now); try value.finishSet(at: now)
        try value.submit(reps: 5, feedback: [], notes: "", at: now)
        var archive = TrainingArchive(); archive.sessions = [value]
        let bytes = try LocalTrainingRepository.encoder().encode(archive)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        var records = try XCTUnwrap(sessions[0]["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "weightConfirmation")
        sessions[0]["records"] = records; sessions[0].removeValue(forKey: "currentWeightConfirmation")
        object["sessions"] = sessions
        let legacy = try LocalTrainingRepository.decoder().decode(TrainingArchive.self, from: JSONSerialization.data(withJSONObject: object))
        try legacy.validate()
        XCTAssertEqual(legacy.sessions[0].records[0].weight, 5)
        XCTAssertNil(legacy.sessions[0].records[0].weightConfirmation)

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        records = try XCTUnwrap(sessions[0]["records"] as? [[String: Any]])
        records[0]["weight"] = 25
        sessions[0]["records"] = records; object["sessions"] = sessions
        let invalid = try LocalTrainingRepository.decoder().decode(TrainingArchive.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try invalid.validate())
    }
}
