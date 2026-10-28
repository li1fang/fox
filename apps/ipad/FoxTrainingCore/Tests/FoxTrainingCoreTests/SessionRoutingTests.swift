import Foundation
import XCTest
@testable import FoxTrainingCore

final class SessionRoutingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fox-sessions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("records.json")
    }
    func plan(_ name: String = "A") -> TrainingPlan {
        TrainingPlan(focus: name, exercises: [Exercise(name: name, sets: [SetTarget(setIndex: 1, reps: 10, weight: 2.5, rest: 30)])])
    }
    func testPreparationIsNotExecutionAndLegacyMissingEvidenceStaysUnknown() throws {
        var session = try TrainingSession(plan: plan(), now: now)
        XCTAssertEqual(session.executionStart, .notStarted)
        XCTAssertNil(session.actualStartedAt)
        try session.startSet(at: now.addingTimeInterval(5))
        XCTAssertEqual(session.actualStartedAt, now.addingTimeInterval(5))
        XCTAssertEqual(session.executionStart, .started)
        try session.finishSet(at: now.addingTimeInterval(8))
        try session.submit(reps: 8, feedback: [], notes: "", at: now.addingTimeInterval(9))
        XCTAssertEqual(session.executionStart, .started)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalTrainingRepository.encoder().encode(try TrainingSession(plan: plan(), now: now))) as? [String: Any])
        raw.removeValue(forKey: "executionStartKnown"); raw.removeValue(forKey: "actualStartedAt")
        let legacy = try LocalTrainingRepository.decoder().decode(TrainingSession.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(legacy.executionStart, .unknown)
        XCTAssertNil(legacy.actualStartedAt)
        var skipped = legacy
        try skipped.skip(at: now)
        XCTAssertEqual(skipped.executionStart, .unknown)
    }
    func testSwitchPreservesAAndExplicitSelectionNeverFallsBackToLast() throws {
        let repo = try LocalTrainingRepository(fileURL: file())
        let a = try repo.switchForeground(.init(target: .new(plan())), expectedRevision: repo.revision, at: now)
        try repo.updateSession(id: a) { try $0.startSet(at: now) }
        let command = TrainingSessionCommand(target: .new(plan("B")))
        let b = try repo.switchForeground(command, expectedRevision: repo.revision, at: now.addingTimeInterval(8))
        XCTAssertEqual(repo.archive.sessions.count, 2)
        XCTAssertEqual(repo.archive.currentSession?.id, b)
        let savedA = try XCTUnwrap(repo.archive.sessions.first { $0.id == a })
        XCTAssertEqual(savedA.stage, .paused)
        XCTAssertNil(savedA.endedAt)
        XCTAssertEqual(savedA.elapsed(at: now.addingTimeInterval(900)), 8)
        XCTAssertEqual(try repo.switchForeground(command, expectedRevision: 0, at: now.addingTimeInterval(100)), b)
        XCTAssertEqual(repo.archive.sessions.count, 2)
        XCTAssertThrowsError(try repo.switchForeground(.init(id: command.id, target: .existing(a)), expectedRevision: repo.revision, at: now))
        _ = try repo.switchForeground(.init(target: .existing(a)), expectedRevision: repo.revision, at: now.addingTimeInterval(100))
        XCTAssertEqual(repo.archive.currentSession?.id, a)
        XCTAssertEqual(repo.archive.currentSession?.stage, .paused)
        XCTAssertThrowsError(try repo.switchForeground(.init(target: .existing(UUID())), expectedRevision: repo.revision, at: now))
        XCTAssertEqual(repo.archive.currentSession?.id, a)
        XCTAssertEqual(try LocalTrainingRepository(fileURL: repo.fileURL).archive.currentSession?.id, a)
    }
    func testFailedSwitchDoesNotPublishBAndRetryCreatesOnce() throws {
        let url = try file()
        var fail = false
        let repo = try LocalTrainingRepository(fileURL: url, writer: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let a = try repo.switchForeground(.init(target: .new(plan())), expectedRevision: repo.revision, at: now)
        try repo.updateSession(id: a) { try $0.startSet(at: now) }
        let before = try Data(contentsOf: url), revision = repo.revision
        let command = TrainingSessionCommand(target: .new(plan("B")))
        fail = true
        XCTAssertThrowsError(try repo.switchForeground(command, expectedRevision: revision, at: now.addingTimeInterval(5)))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(repo.archive.currentSession?.id, a)
        XCTAssertEqual(repo.archive.sessions.count, 1)
        fail = false
        _ = try repo.switchForeground(command, expectedRevision: revision, at: now.addingTimeInterval(5))
        XCTAssertEqual(repo.archive.sessions.count, 2)
        XCTAssertEqual(repo.archive.sessions.first?.accumulatedSeconds, 5)
    }
    func testLegacyReadIsBytePreservingAndFailedMigrationRetainsOriginal() throws {
        let url = try file()
        var archive = TrainingArchive()
        archive.schemaVersion = 1
        archive.sessions = [try TrainingSession(plan: plan(), now: now)]
        let original = try LocalTrainingRepository.encoder().encode(archive)
        try original.write(to: url)
        var fail = true
        let repo = try LocalTrainingRepository(fileURL: url, writer: { data, path in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: path, options: .atomic)
        })
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.legacyBackupURL.path))
        XCTAssertThrowsError(try repo.updateSession(id: archive.sessions[0].id) { try $0.startSet(at: self.now) })
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: repo.legacyBackupURL), original)
        fail = false
        try repo.updateSession(id: archive.sessions[0].id) { try $0.startSet(at: self.now) }
        XCTAssertEqual(repo.archive.schemaVersion, 2)
        XCTAssertEqual(try Data(contentsOf: repo.legacyBackupURL), original)
        XCTAssertEqual(repo.archive.sessions[0].id, archive.sessions[0].id)
    }
    func testStaleWriterAndInvalidForegroundCannotOverwrite() throws {
        let url = try file()
        let first = try LocalTrainingRepository(fileURL: url)
        let second = try LocalTrainingRepository(fileURL: url)
        let a = try first.switchForeground(.init(target: .new(plan())), expectedRevision: first.revision, at: now)
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try second.start(plan: plan("stale"), at: now))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        var invalid = first.archive
        invalid.foregroundSessionID = UUID()
        XCTAssertThrowsError(try invalid.validate())
        var other = try TrainingSession(plan: plan("B"), now: now)
        try other.startSet(at: now)
        invalid = first.archive; invalid.sessions.append(other)
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertEqual(first.archive.currentSession?.id, a)
    }
    func testOldSameAttemptSnapshotCannotRollBackCommittedExecution() throws {
        let repo = try LocalTrainingRepository(fileURL: file())
        let a = try repo.switchForeground(.init(target: .new(plan())), expectedRevision: repo.revision, at: now)
        let snapshot = try XCTUnwrap(repo.switchSnapshot())
        try repo.updateSession(id: a) { try $0.startSet(at: now) }
        let bytes = try Data(contentsOf: repo.fileURL)
        XCTAssertThrowsError(try repo.switchForeground(.init(target: .new(plan("B"))), expectedRevision: repo.revision, at: now, preserving: snapshot))
        XCTAssertEqual(try Data(contentsOf: repo.fileURL), bytes)
    }
    func testNonForegroundTimerAndDanglingReceiptsAreCorrupt() throws {
        let repo = try LocalTrainingRepository(fileURL: file())
        let a = try repo.switchForeground(.init(target: .new(plan())), expectedRevision: repo.revision, at: now)
        _ = try repo.switchForeground(.init(target: .new(plan("B"))), expectedRevision: repo.revision, at: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalTrainingRepository.encoder().encode(repo.archive)) as? [String: Any])
        var sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        sessions[0]["segmentStartedAt"] = "2023-11-14T22:13:20Z"
        object["sessions"] = sessions
        let corrupt = try LocalTrainingRepository.decoder().decode(TrainingArchive.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try corrupt.validate())
        var invalid = repo.archive
        invalid.commandReceipts = [.init(command: .init(target: .existing(a)), sessionID: UUID())]
        XCTAssertThrowsError(try invalid.validate())
    }
}
