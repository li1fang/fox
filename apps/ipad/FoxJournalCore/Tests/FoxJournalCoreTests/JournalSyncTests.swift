import Foundation
import SQLite3
import XCTest
@testable import FoxJournalCore

final class JournalSyncTests: XCTestCase {
    var roots: [URL] = []
    func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fox-sync-test-\(UUID())")
        roots.append(url); return url
    }
    override func tearDownWithError() throws { for url in roots { try? FileManager.default.removeItem(at: url) } }
    func store() throws -> LocalJournalRepository { try LocalJournalRepository(directory: root()) }

    func testPairingSeedsHistoryAndContinuousOfflineEditsRemainImmutable() throws {
        let s = try store(), first = try s.record(.init(note: "first"))
        try s.enableSync(vault: "vault")
        let original = try XCTUnwrap(s.syncPending().first)
        var edit = CaptureEdit(from: first); edit.note = "second"
        _ = try s.revise(first.id, expectedRevision: 1, edit: edit)
        let pending = try s.syncPending()
        XCTAssertEqual(pending.count, 2); XCTAssertEqual(pending[0], original)
        XCTAssertEqual(pending[1].base, original.op_id)
        try s.enableSync(vault: "vault"); XCTAssertEqual(try s.syncPending(), pending)
        XCTAssertThrowsError(try s.enableSync(vault: "other"))
    }

    func testOutboxAndRecordRollbackTogether() throws {
        let dir = root(), s = try LocalJournalRepository(directory: dir)
        try s.enableSync(vault: "vault")
        let faulty = try LocalJournalRepository(directory: dir, limits: .init()) { if case .beforeCommit = $0 { throw JournalError.ioFailure } }
        XCTAssertThrowsError(try faulty.record(.init(note: "not committed")))
        XCTAssertTrue(try s.list().isEmpty); XCTAssertTrue(try s.syncPending().isEmpty)
    }

    func testPairedDeletionPreservesHistoryPhotoAndBackupTombstone() throws {
        let s = try store(), photo = Data([1,2,3])
        let r = try s.record(.init(note: "photo", photos: [.init(data: photo, mimeType: "image/png")]))
        try s.enableSync(vault: "vault")
        _ = try s.delete(r.id, expectedRevision: 1)
        XCTAssertNil(try s.get(r.id)); XCTAssertEqual(try s.history(r.id), [r])
        XCTAssertEqual(try s.photoData(r.photos[0].id), photo)
        XCTAssertTrue(try XCTUnwrap(s.syncPending().last).deleted)
        let backup = root(); _ = try s.exportBackup(to: backup)
        let restored = try store(); _ = try restored.restoreBackup(from: backup)
        XCTAssertNil(try restored.get(r.id)); XCTAssertEqual(try restored.history(r.id), [r])
        XCTAssertEqual(try restored.photoData(r.photos[0].id), photo)
    }

    func testPullPreservesPendingLocalEditAndConflictBlocksDescendants() throws {
        let s = try store(), r = try s.record(.init(note: "local"))
        try s.enableSync(vault: "vault")
        let first = try XCTUnwrap(s.syncPending().first)
        var edit = CaptureEdit(from: r); edit.note = "new local"
        _ = try s.revise(r.id, expectedRevision: 1, edit: edit)
        let remote = JournalSyncOperation(op_id: "remote", record_id: r.id.uuidString.lowercased(), base: nil, deleted: false, payload: r)
        try s.syncApply(.init(vault: "vault", events: [.init(seq: 1, operation: remote)], cursor: 1, more: false), expectedCursor: 0, photos: [:])
        XCTAssertEqual(try s.get(r.id)?.note, "new local")
        try s.syncAcknowledge(first, receipt: .init(status: "conflict", head: remote))
        XCTAssertTrue(try s.syncPending().isEmpty)
        XCTAssertEqual(try s.syncStatus().conflicts, 2)
        XCTAssertEqual(try s.history(r.id).count, 2)
    }

    func testInvalidPageOrPhotoNeverAdvancesCursor() throws {
        let a = try store(), b = try store()
        try a.enableSync(vault: "vault"); try b.enableSync(vault: "vault")
        _ = try a.record(.init(note: "photo", photos: [.init(data: Data([7]), mimeType: "image/png")]))
        let op = try XCTUnwrap(a.syncPending().first)
        let page = JournalSyncPage(vault: "vault", events: [.init(seq: 1, operation: op)], cursor: 1, more: false)
        XCTAssertThrowsError(try b.syncApply(page, expectedCursor: 0, photos: [:]))
        XCTAssertEqual(try b.syncStatus().cursor, 0); XCTAssertTrue(try b.list().isEmpty)
        let p = try XCTUnwrap(op.payload?.photos.first)
        try b.syncApply(page, expectedCursor: 0, photos: [p.id: Data([7])])
        XCTAssertEqual(try b.syncStatus().cursor, 1); XCTAssertEqual(try b.photoData(p.id), Data([7]))
        XCTAssertThrowsError(try b.syncApply(page, expectedCursor: 0, photos: [:]))
        XCTAssertEqual(try b.list().count, 1)
    }

    func testVersionOneMigrationPreservesIdentityAndRejectsForeignDatabase() throws {
        let dir = root(), s = try LocalJournalRepository(directory: dir)
        let r = try s.record(.init(note: "old", photos: [.init(data: Data([1]), mimeType: "image/png")])), device = s.deviceID
        var edit = CaptureEdit(from: r); edit.note = "revised"; edit.newPhotos = [.init(data: Data([2]), mimeType: "image/png")]
        let revised = try s.revise(r.id, expectedRevision: 1, edit: edit)
        let db = try JournalDatabase(url: dir.appendingPathComponent("journal.sqlite"))
        // Recreate the precise pre-sync schema marker/tables, without replacing source records.
        for name in ["sync_photo_refs", "sync_downloads", "sync_outbox", "sync_events", "sync_heads", "sync_conflict_heads", "sync_archive", "journal_tombstones"] { try db.execute("DROP TABLE IF EXISTS \(name)") }
        try db.execute("PRAGMA user_version=1")
        let migrated = try LocalJournalRepository(directory: dir)
        XCTAssertEqual(migrated.deviceID, device); XCTAssertEqual(try migrated.get(r.id), revised)
        XCTAssertEqual(try migrated.history(r.id), [r, revised])
        XCTAssertEqual(try migrated.photoData(r.photos[0].id), Data([1]))
        XCTAssertEqual(try migrated.photoData(revised.photos[1].id), Data([2]))
        try migrated.enableSync(vault: "vault"); XCTAssertEqual(try migrated.syncPending().count, 2)
    }
    func testConflictSelectionWaitsForVerifiedRemotePageAndRejectsUnknownFields() throws {
        let s = try store(), r = try s.record(.init(note: "local"))
        try s.enableSync(vault: "vault")
        let pending = try XCTUnwrap(s.syncPending().first)
        let remote = JournalSyncOperation(op_id: "remote", record_id: pending.record_id, base: nil, deleted: false, payload: r)
        try s.syncAcknowledge(pending, receipt: .init(status: "conflict", head: remote))
        XCTAssertTrue(try s.syncConflicts().isEmpty)
        XCTAssertThrowsError(try s.resolveSyncConflict(r.id, keepLocal: false))
        let page = JournalSyncPage(vault: "vault", events: [.init(seq: 1, operation: remote)], cursor: 1, more: false)
        var wire = try JSONSerialization.jsonObject(with: JournalJSON.encoder().encode(page)) as! [String: Any]
        wire["unexpected"] = true
        XCTAssertThrowsError(try JournalSyncPage.decode(JSONSerialization.data(withJSONObject: wire)))
        try s.syncApply(page, expectedCursor: 0, photos: [:])
        XCTAssertEqual(try s.syncConflicts().count, 1)
    }
    func testAcknowledgementFailureAndReopenDoNotLosePendingEdits() throws {
        let dir = root(), s = try LocalJournalRepository(directory: dir)
        try s.enableSync(vault: "vault")
        _ = try s.record(.init(note: "original"))
        let op = try XCTUnwrap(s.syncPending().first)
        XCTAssertThrowsError(try s.syncAcknowledge(op, receipt: .init(status: "accepted", seq: 1, revision: "wrong")))
        let reopened = try LocalJournalRepository(directory: dir)
        XCTAssertEqual(try reopened.syncPending(), [op])
        try reopened.syncAcknowledge(op, receipt: .init(status: "accepted", seq: 1, revision: op.op_id))
        XCTAssertTrue(try reopened.syncPending().isEmpty)
        XCTAssertEqual(try reopened.list().count, 1)
    }
    func testBackfillDoesNotRegressAcknowledgedHeadDuringNewEdit() throws {
        let s = try store(); try s.enableSync(vault: "vault")
        let first = try s.record(.init(note: "one"))
        var edit = CaptureEdit(from: first); edit.note = "two"
        let second = try s.revise(first.id, expectedRevision: 1, edit: edit)
        let ops = try s.syncPending()
        for (i,op) in ops.enumerated() { try s.syncAcknowledge(op, receipt: .init(status: "accepted", seq: i + 1, revision: op.op_id)) }
        try s.syncApply(.init(vault: "vault", events: [.init(seq: 1, operation: ops[0])], cursor: 1, more: true), expectedCursor: 0, photos: [:])
        var third = CaptureEdit(from: second); third.note = "three"
        _ = try s.revise(first.id, expectedRevision: 2, edit: third)
        XCTAssertEqual(try s.syncPending().last?.base, ops[1].op_id)
    }
    func testV2ConflictOnlyPhotoRestoresAndNonemptyOrPairedTargetsStayUnchanged() throws {
        let s = try store(), remoteStore = try store()
        let local = try s.record(.init(note: "local"))
        let remote = try remoteStore.record(.init(note: "remote", photos: [.init(data: Data([9]), mimeType: "image/png")]))
        try s.enableSync(vault: "vault")
        let payload = CaptureRecord(schemaVersion: 1, id: local.id, revision: 1, recordedAt: local.recordedAt,
            updatedAt: local.updatedAt, timeZoneIdentifier: local.timeZoneIdentifier, note: remote.note, photos: remote.photos,
            occurred: nil, labels: [], source: local.source)
        let op = JournalSyncOperation(op_id: "remote", record_id: local.id.uuidString.lowercased(), base: nil, deleted: false, payload: payload)
        try s.syncApply(.init(vault: "vault", events: [.init(seq: 1, operation: op)], cursor: 1, more: false), expectedCursor: 0, photos: [remote.photos[0].id: Data([9])])
        let backup = root(); _ = try s.exportBackup(to: backup)
        let bytes = try Data(contentsOf: backup.appendingPathComponent("manifest.json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("token"))
        let dir = root(), restored = try LocalJournalRepository(directory: dir)
        _ = try restored.restoreBackup(from: backup)
        let reopened = try LocalJournalRepository(directory: dir); _ = try reopened.cleanup()
        XCTAssertEqual(try reopened.photoData(remote.photos[0].id), Data([9]))
        let target = try store(), original = try target.record(.init(note: "untouched"))
        XCTAssertThrowsError(try target.restoreBackup(from: backup))
        XCTAssertEqual(try target.list(), [original])
        let paired = try store(); try paired.enableSync(vault: "vault")
        XCTAssertThrowsError(try paired.restoreBackup(from: backup))
        XCTAssertEqual(try paired.syncStatus().cursor, 0); XCTAssertTrue(try paired.syncPending().isEmpty)
        if let path = ProcessInfo.processInfo.environment["FOX_JOURNAL_SYNC_SCHEMA_FIXTURE"] { try bytes.write(to: URL(fileURLWithPath: path)) }
    }
    func testStagedPhotoSurvivesRestartWithoutAdvancingCursor() throws {
        let source = try store(), r = try source.record(.init(note: "photo", photos: [.init(data: Data([5]), mimeType: "image/png")]))
        let dir = root(), target = try LocalJournalRepository(directory: dir); try target.enableSync(vault: "vault")
        try target.syncStorePhoto(r.photos[0], data: Data([5]))
        let reopened = try LocalJournalRepository(directory: dir)
        XCTAssertEqual(try reopened.syncStatus().cursor, 0); XCTAssertTrue(try reopened.list().isEmpty)
        XCTAssertEqual(try reopened.photoData(r.photos[0].id), Data([5]))
    }
}
