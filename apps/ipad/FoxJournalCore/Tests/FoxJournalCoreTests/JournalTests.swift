import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import FoxJournalCore

final class JournalTests: XCTestCase {
    private var roots: [URL] = []
    private let now = Date(timeIntervalSince1970: 1_792_102_800.125)
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jQn0AAAAASUVORK5CYII=")!
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fox-journal-test-\(UUID())")
        roots.append(url); return url
    }
    private func draft(_ text: String? = "起床了，感觉头痛", photos: Bool = false) -> CaptureDraft {
        CaptureDraft(recordedAt: now, timeZoneIdentifier: "Asia/Bangkok", note: text,
                     photos: photos ? [.init(data: png, mimeType: "image/png")] : [])
    }
    private func copy(_ source: URL) throws -> URL {
        let destination = root(); try FileManager.default.copyItem(at: source, to: destination); return destination
    }
    override func tearDownWithError() throws {
        for url in roots { try? FileManager.default.removeItem(at: url) }
    }

    func testTextOnlyRecordSurvivesReopenWithoutInventedOccurrenceOrDomain() throws {
        let dir = root(), store = try LocalJournalRepository(directory: dir)
        let record = try store.record(draft())
        XCTAssertEqual(record.note, "起床了，感觉头痛"); XCTAssertNil(record.occurred)
        XCTAssertEqual(record.recordedAt, now); XCTAssertEqual(record.revision, 1)
        XCTAssertEqual(record.source.kind, .user); XCTAssertEqual(record.source.deviceID, store.deviceID)
        XCTAssertEqual(record.labels, []); XCTAssertEqual(record.photos, [])
        let reopened = try LocalJournalRepository(directory: dir)
        XCTAssertEqual(reopened.deviceID, store.deviceID)
        XCTAssertEqual(try reopened.get(record.id), record)
        XCTAssertEqual(try reopened.list(), [record])
    }

    func testPhotoOnlyCapturePreservesBytesAndDigest() throws {
        let store = try LocalJournalRepository(directory: root())
        let record = try store.record(draft(nil, photos: true))
        let photo = try XCTUnwrap(record.photos.first)
        XCTAssertEqual(try store.photoData(photo.id), png)
        XCTAssertEqual(photo.byteCount, png.count)
        XCTAssertEqual(photo.sha256, SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(photo.relativePath, "attachments/\(photo.id.uuidString.lowercased()).png")
    }

    func testRecordedTimeAndApproximateIntervalStayDistinct() throws {
        let store = try LocalJournalRepository(directory: root())
        var input = draft("早上大概八点醒了")
        input.occurred = .init(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-7100),
                               timeZoneIdentifier: "Asia/Bangkok", precision: .approximate)
        let record = try store.record(input)
        XCTAssertEqual(record.timelineAt, input.occurred?.start)
        XCTAssertEqual(record.recordedAt, now); XCTAssertEqual(record.occurred?.precision, .approximate)
        XCTAssertEqual(try store.get(record.id), record)
    }

    func testInvalidAndOversizedInputsDoNotCreateRecords() throws {
        var limits = JournalLimits(); limits.noteBytes = 8; limits.photosPerRecord = 1
        limits.photoBytes = png.count; limits.recordPhotoBytes = png.count
        let store = try LocalJournalRepository(directory: root(), limits: limits)
        for text in [nil, "", "  \n", "123456789"] { XCTAssertThrowsError(try store.record(draft(text))) }
        var input = draft("x", photos: true); input.photos.append(input.photos[0])
        XCTAssertThrowsError(try store.record(input))
        input.photos = [.init(data: png + Data([0]), mimeType: "image/png")]
        XCTAssertThrowsError(try store.record(input))
        input.photos = [.init(data: Data(), mimeType: "image/png")]
        XCTAssertThrowsError(try store.record(input))
        input.photos = [.init(data: png, mimeType: "text/html")]
        XCTAssertThrowsError(try store.record(input))
        input = draft("x"); input.timeZoneIdentifier = "invalid/timezone"
        XCTAssertThrowsError(try store.record(input))
        input = draft("x"); input.occurred = .init(start: now, end: now.addingTimeInterval(-1), timeZoneIdentifier: "UTC")
        XCTAssertThrowsError(try store.record(input))
        input = draft("x"); input.recordedAt = Date(timeIntervalSince1970: .nan)
        XCTAssertThrowsError(try store.record(input))
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testStableCaptureIDRetryDoesNotDuplicateOrUndoLaterEdit() throws {
        let store = try LocalJournalRepository(directory: root()), input = draft(photos: true)
        let first = try store.record(input)
        XCTAssertEqual(try store.record(input), first)
        var edit = CaptureEdit(from: first); edit.note = "刚才的头痛已经缓解"
        let revised = try store.revise(first.id, expectedRevision: 1, edit: edit, at: now.addingTimeInterval(1))
        XCTAssertEqual(try store.record(input), revised)
        var conflicting = input; conflicting.note = "different capture"
        XCTAssertThrowsError(try store.record(conflicting))
        XCTAssertEqual(try store.list().count, 1)
    }

    func testEditRetainsOriginalAndPhotoHistoryButRejectsStaleWrites() throws {
        let store = try LocalJournalRepository(directory: root())
        let first = try store.record(draft("买了两块羊排，400 克，80 元", photos: true))
        var edit = CaptureEdit(from: first); edit.note = "更正：价格是 75 元"; edit.keepPhotoIDs = []
        edit.newPhotos = [.init(data: png + Data([1]), mimeType: "image/png")]; edit.labels = ["消费", "饮食"]
        let second = try store.revise(first.id, expectedRevision: 1, edit: edit, at: now.addingTimeInterval(1))
        XCTAssertEqual(second.recordedAt, first.recordedAt); XCTAssertEqual(second.source, first.source)
        XCTAssertEqual(second.revision, 2); XCTAssertEqual(try store.history(first.id), [first, second])
        XCTAssertEqual(try store.photoData(first.photos[0].id), png)
        XCTAssertThrowsError(try store.revise(first.id, expectedRevision: 1, edit: edit))
        XCTAssertThrowsError(try store.delete(first.id, expectedRevision: 1))
        edit.keepPhotoIDs = [UUID()]
        XCTAssertThrowsError(try store.revise(first.id, expectedRevision: 2, edit: edit))
        XCTAssertEqual(try store.get(first.id), second)
    }

    func testLiteralSearchLabelsTimeRangesAndPagination() throws {
        let store = try LocalJournalRepository(directory: root())
        var a = draft("羊排 100%_\\ ' OR 1=1 --"); a.labels = ["购买"]
        a.occurred = .init(start: now.addingTimeInterval(-100), timeZoneIdentifier: "UTC")
        let first = try store.record(a)
        let second = try store.record(draft("吃了昨天买的羊排"))
        XCTAssertEqual(try store.list(.init(text: "%_\\")), [first])
        XCTAssertEqual(try store.list(.init(label: "购买")), [first])
        XCTAssertEqual(try store.list(.init(from: now.addingTimeInterval(-101), before: now)), [first])
        XCTAssertEqual(try store.list(.init(from: now, before: now.addingTimeInterval(1))).map(\.id), [second.id])
        XCTAssertEqual(try store.list(.init(from: now, before: now.addingTimeInterval(1), timeBasis: .recorded)).count, 2)
        let all = try store.list()
        XCTAssertEqual(try store.list(.init(limit: 1)) + store.list(.init(limit: 1, offset: 1)), all)
        XCTAssertThrowsError(try store.list(.init(limit: 0)))
    }

    func testDeleteRemovesAllRevisionsAndPhotosWithoutTouchingOtherRecords() throws {
        let store = try LocalJournalRepository(directory: root())
        let first = try store.record(draft(photos: true)), other = try store.record(draft("另一条", photos: true))
        var edit = CaptureEdit(from: first); edit.note = "edited"
        _ = try store.revise(first.id, expectedRevision: 1, edit: edit)
        XCTAssertTrue(try store.delete(first.id, expectedRevision: 2).complete)
        XCTAssertNil(try store.get(first.id)); XCTAssertThrowsError(try store.photoData(first.photos[0].id))
        XCTAssertEqual(try store.get(other.id), other); XCTAssertEqual(try store.photoData(other.photos[0].id), png)
    }

    func testDeletionFailureIsReportedAndReopenRetriesPhysicalCleanup() throws {
        let dir = root()
        let store = try LocalJournalRepository(directory: dir, checkpoint: { if case .beforePhotoRemoval = $0 { throw JournalError.ioFailure } })
        let record = try store.record(draft(photos: true))
        XCTAssertEqual(try store.delete(record.id, expectedRevision: 1).pendingPhotoIDs, record.photos.map(\.id))
        XCTAssertNil(try store.get(record.id))
        let reopened = try LocalJournalRepository(directory: dir)
        XCTAssertTrue(try reopened.cleanup().complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(record.photos[0].relativePath).path))
    }

    func testFailedPhotoAndMetadataWritesNeverLeaveHalfARecord() throws {
        for checkpoint in [JournalCheckpoint.photoWritten, .beforeCommit] {
            let dir = root(), healthy = try LocalJournalRepository(directory: dir)
            let original = try healthy.record(draft("保留原记录", photos: true))
            let faulty = try LocalJournalRepository(directory: dir, checkpoint: { point in
                switch (checkpoint, point) {
                case (.photoWritten, .photoWritten), (.beforeCommit, .beforeCommit): throw JournalError.ioFailure
                default: break
                }
            })
            XCTAssertThrowsError(try faulty.record(draft("不能半条落库", photos: true)))
            let reopened = try LocalJournalRepository(directory: dir)
            XCTAssertEqual(try reopened.list(), [original]); XCTAssertEqual(try reopened.photoData(original.photos[0].id), png)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("attachments").path).count, 1)
        }
    }

    func testBackupRestoresTextPhotosHistoryAndIsIdempotent() throws {
        let source = try LocalJournalRepository(directory: root())
        let first = try source.record(draft(photos: true))
        var edit = CaptureEdit(from: first); edit.note = "更正记录"
        let second = try source.revise(first.id, expectedRevision: 1, edit: edit, at: now.addingTimeInterval(2))
        _ = try source.record(draft("只留文字"))
        let backup = root(), manifest = try source.exportBackup(to: backup, at: now.addingTimeInterval(3))
        XCTAssertEqual(manifest.format, "fox.journal.backup.v1")
        let destination = try LocalJournalRepository(directory: root())
        XCTAssertEqual(try destination.restoreBackup(from: backup), .init(inserted: 2, unchanged: 0))
        XCTAssertEqual(try destination.restoreBackup(from: backup), .init(inserted: 0, unchanged: 2))
        XCTAssertEqual(try destination.get(first.id), second)
        XCTAssertEqual(try destination.history(first.id), [first, second])
        XCTAssertEqual(try destination.photoData(first.photos[0].id), png)
        XCTAssertNotEqual(destination.deviceID, source.deviceID)
    }

    func testRestoreConflictDoesNotOverwriteOrPartiallyImport() throws {
        let source = try LocalJournalRepository(directory: root()), first = try source.record(draft(photos: true))
        let backup = root(); _ = try source.exportBackup(to: backup)
        let target = try LocalJournalRepository(directory: root()); _ = try target.restoreBackup(from: backup)
        var edit = CaptureEdit(from: first); edit.note = "本机修改"
        let local = try target.revise(first.id, expectedRevision: 1, edit: edit)
        _ = try source.record(draft("新条目不应在冲突时半导入"))
        let newerBackup = root(); _ = try source.exportBackup(to: newerBackup)
        XCTAssertThrowsError(try target.restoreBackup(from: newerBackup))
        XCTAssertEqual(try target.list(), [local])
    }

    func testMissingTamperedOrTraversingBackupCannotEnterStorage() throws {
        let source = try LocalJournalRepository(directory: root()), record = try source.record(draft(photos: true))
        let backup = root(); _ = try source.exportBackup(to: backup)
        for mode in ["missing", "tampered", "path", "version"] {
            let bad = try copy(backup), target = try LocalJournalRepository(directory: root())
            let photo = bad.appendingPathComponent(record.photos[0].relativePath)
            if mode == "missing" { try FileManager.default.removeItem(at: photo) }
            if mode == "tampered" { try Data([9]).write(to: photo) }
            if mode == "path" || mode == "version" {
                let url = bad.appendingPathComponent("manifest.json")
                var manifest = try JournalJSON.decoder().decode(JournalBackup.self, from: Data(contentsOf: url))
                if mode == "path" { manifest.photos[0].relativePath = "../outside.png" }
                else { manifest.format = "fox.journal.backup.v99" }
                try JournalJSON.encoder().encode(manifest).write(to: url)
            }
            XCTAssertThrowsError(try target.restoreBackup(from: bad), mode)
            XCTAssertTrue(try target.list().isEmpty, mode)
        }
    }

    func testRestoreWriteFailureRollsBackAllRowsAndPhotos() throws {
        let source = try LocalJournalRepository(directory: root()); _ = try source.record(draft(photos: true))
        let backup = root(); _ = try source.exportBackup(to: backup)
        let dir = root(), target = try LocalJournalRepository(directory: dir, checkpoint: {
            if case .beforeCommit = $0 { throw JournalError.ioFailure }
        })
        XCTAssertThrowsError(try target.restoreBackup(from: backup))
        let reopened = try LocalJournalRepository(directory: dir)
        XCTAssertTrue(try reopened.list().isEmpty)
        XCTAssertTrue(try reopened.cleanup().complete)
    }

    func testExistingBackupAndFailedExportAreNeverPublishedOverPreviousData() throws {
        let source = try LocalJournalRepository(directory: root()); _ = try source.record(draft(photos: true))
        let backup = root(); let manifest = try source.exportBackup(to: backup)
        XCTAssertThrowsError(try source.exportBackup(to: backup))
        XCTAssertEqual(try JournalJSON.decoder().decode(JournalBackup.self, from: Data(contentsOf: backup.appendingPathComponent("manifest.json"))), manifest)
        let dir = root(), faulty = try LocalJournalRepository(directory: dir, checkpoint: {
            if case .backupPhotoCopied = $0 { throw JournalError.ioFailure }
        })
        _ = try faulty.record(draft(photos: true))
        let failed = root(); XCTAssertThrowsError(try faulty.exportBackup(to: failed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
    }

    func testSymlinkedPhotoAndBackupRootAreRejected() throws {
        let dir = root(), source = try LocalJournalRepository(directory: dir)
        let record = try source.record(draft(photos: true)), external = root()
        try png.write(to: external)
        let photo = dir.appendingPathComponent(record.photos[0].relativePath)
        try FileManager.default.removeItem(at: photo)
        try FileManager.default.createSymbolicLink(at: photo, withDestinationURL: external)
        XCTAssertThrowsError(try source.photoData(record.photos[0].id))
        XCTAssertThrowsError(try source.exportBackup(to: root()))
        let alias = root(); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        XCTAssertThrowsError(try LocalJournalRepository(directory: alias))
        XCTAssertEqual(try Data(contentsOf: external), png)
    }

    func testCorruptDatabaseAndFutureVersionAreNotReset() throws {
        let corrupt = root(); try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let bytes = Data("not sqlite".utf8), url = corrupt.appendingPathComponent("journal.sqlite")
        try bytes.write(to: url)
        XCTAssertThrowsError(try LocalJournalRepository(directory: corrupt))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let future = root(); _ = try LocalJournalRepository(directory: future)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(future.appendingPathComponent("journal.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: future.appendingPathComponent("journal.sqlite"))
        XCTAssertThrowsError(try LocalJournalRepository(directory: future))
        XCTAssertEqual(try Data(contentsOf: future.appendingPathComponent("journal.sqlite")), before)
    }

    func testTwoConnectionsRespectRevisionCompareAndSwap() throws {
        let dir = root(), a = try LocalJournalRepository(directory: dir), b = try LocalJournalRepository(directory: dir)
        let first = try a.record(draft()); var edit = CaptureEdit(from: first); edit.note = "第一次修改"
        let second = try b.revise(first.id, expectedRevision: 1, edit: edit)
        XCTAssertThrowsError(try a.revise(first.id, expectedRevision: 1, edit: edit))
        XCTAssertEqual(try a.get(first.id), second)
    }

    func testBackupLimitDoesNotPreventReadingOrDeletingStoredHistory() throws {
        var limits = JournalLimits(); limits.backupBytes = png.count
        let store = try LocalJournalRepository(directory: root(), limits: limits)
        let first = try store.record(draft(photos: true))
        var edit = CaptureEdit(from: first); edit.keepPhotoIDs = []
        edit.newPhotos = [.init(data: png + Data([2]), mimeType: "image/png")]
        let revised = try store.revise(first.id, expectedRevision: 1, edit: edit)
        XCTAssertEqual(try store.history(first.id), [first, revised])
        XCTAssertThrowsError(try store.exportBackup(to: root()))
        XCTAssertTrue(try store.delete(first.id, expectedRevision: 2).complete)
    }

    func testUnknownBackupFieldsAreRejectedInsteadOfSilentlyDiscarded() throws {
        let store = try LocalJournalRepository(directory: root()); _ = try store.record(draft())
        let backup = root(); _ = try store.exportBackup(to: backup)
        let url = backup.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["unrecognized_future_facts"] = ["must not disappear"]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let target = try LocalJournalRepository(directory: root())
        XCTAssertThrowsError(try target.restoreBackup(from: backup))
        XCTAssertTrue(try target.list().isEmpty)
    }

    func testEmbeddedNulAndUnicodeTextRoundTripWithoutTruncation() throws {
        let store = try LocalJournalRepository(directory: root())
        let text = "羊排\u{0000}第二段：75 元"
        let record = try store.record(draft(text))
        XCTAssertEqual(try store.get(record.id)?.note, text)
        XCTAssertEqual(try store.list(.init(text: "第二段")), [record])
    }

    func testExternalProvenanceAndInvalidSourcesAreExplicit() throws {
        let store = try LocalJournalRepository(directory: root())
        var input = draft("外部来源的原始文本，不生成健康测量")
        input.source = CaptureSource(kind: .external, deviceID: UUID(), provider: "fixture.provider", sourceRecordID: "record-1")
        let record = try store.record(input)
        XCTAssertEqual(try store.get(record.id)?.source, input.source)
        var invalid = draft(); invalid.source = .init(kind: .external, deviceID: UUID())
        XCTAssertThrowsError(try store.record(invalid))
        invalid.source = .init(kind: .user, deviceID: UUID(), provider: "not allowed")
        XCTAssertThrowsError(try store.record(invalid))
        XCTAssertEqual(try store.list().count, 1)
    }

    func testFailedRevisionAndDeletionLeaveExistingRecordUntouched() throws {
        let dir = root(), healthy = try LocalJournalRepository(directory: dir)
        let first = try healthy.record(draft(photos: true))
        let faulty = try LocalJournalRepository(directory: dir, checkpoint: { if case .beforeCommit = $0 { throw JournalError.ioFailure } })
        var edit = CaptureEdit(from: first); edit.newPhotos = [.init(data: png, mimeType: "image/png")]
        XCTAssertThrowsError(try faulty.revise(first.id, expectedRevision: 1, edit: edit))
        XCTAssertThrowsError(try faulty.delete(first.id, expectedRevision: 1))
        XCTAssertEqual(try healthy.get(first.id), first)
        XCTAssertEqual(try healthy.history(first.id), [first])
        XCTAssertEqual(try healthy.photoData(first.photos[0].id), png)
    }

    func testUnrelatedDatabaseIsNotAdoptedAsJournal() throws {
        let dir = root(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = dir.appendingPathComponent("journal.sqlite")
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE keep_me(value TEXT); INSERT INTO keep_me VALUES('important')", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: path)
        XCTAssertThrowsError(try LocalJournalRepository(directory: dir))
        XCTAssertEqual(try Data(contentsOf: path), before)
    }

    func testPortableFixtureCanBeValidatedOutsideSwift() throws {
        let store = try LocalJournalRepository(directory: root())
        let record = try store.record(draft(photos: true))
        var edit = CaptureEdit(from: record); edit.note = "更正留言，保留原照片"
        _ = try store.revise(record.id, expectedRevision: 1, edit: edit)
        _ = try store.record(draft("买了两块烤羊排，400 克，80 元"))
        _ = try store.record(draft("吃了昨天买的一块羊排"))
        let backup = root(), manifest = try store.exportBackup(to: backup)
        let json = try JournalJSON.encoder().encode(manifest)
        XCTAssertEqual(try JournalJSON.decoder().decode(JournalBackup.self, from: json), manifest)
        if let path = ProcessInfo.processInfo.environment["FOX_JOURNAL_SCHEMA_FIXTURE"] {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.write(to: url, options: .atomic)
        }
    }

    func testSmallerNewInputLimitsDoNotHideOrEraseExistingRecords() throws {
        let dir = root(), first = try LocalJournalRepository(directory: dir).record(draft(photos: true))
        var limits = JournalLimits(); limits.noteBytes = 1; limits.photoBytes = 1; limits.recordPhotoBytes = 1
        let reopened = try LocalJournalRepository(directory: dir, limits: limits)
        XCTAssertEqual(try reopened.get(first.id), first)
        XCTAssertEqual(try reopened.history(first.id), [first])
        XCTAssertEqual(try reopened.photoData(first.photos[0].id), png)
        XCTAssertThrowsError(try reopened.record(draft(photos: true)))
        XCTAssertTrue(try reopened.delete(first.id, expectedRevision: 1).complete)
    }

    func testParallelConnectionsAndRecoveryPreserveAllCommittedPhotos() throws {
        let dir = root(), a = try LocalJournalRepository(directory: dir), b = try LocalJournalRepository(directory: dir)
        final class Failures: @unchecked Sendable {
            let lock = NSLock()
            var values: [String] = []
            func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        }
        let failures = Failures(), bytes = png, time = now
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do {
                let writer = index.isMultiple(of: 2) ? a : b
                let recovery = index.isMultiple(of: 2) ? b : a
                _ = try writer.record(.init(recordedAt: time, note: "parallel \(index)", photos: [.init(data: bytes, mimeType: "image/png")]))
                _ = try recovery.cleanup()
            } catch { failures.append(String(describing: error)) }
        }
        XCTAssertEqual(failures.values, [])
        let records = try a.list()
        XCTAssertEqual(records.count, 24)
        for record in records { XCTAssertEqual(try b.photoData(record.photos[0].id), png) }
    }

    func testSharedBackupAttachmentRemainsUntilItsLastRecordIsDeleted() throws {
        let source = try LocalJournalRepository(directory: root())
        let first = try source.record(draft(photos: true)), second = try source.record(draft("另一条", photos: true))
        let backup = root(); _ = try source.exportBackup(to: backup)
        let url = backup.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let sharedPhoto = try JSONSerialization.jsonObject(with: JournalJSON.encoder().encode(first.photos[0]))
        var histories = try XCTUnwrap(json["records"] as? [[String: Any]])
        for index in histories.indices {
            var revisions = try XCTUnwrap(histories[index]["revisions"] as? [[String: Any]])
            revisions[0]["photos"] = [sharedPhoto]; histories[index]["revisions"] = revisions
        }
        json["records"] = histories; json["photos"] = [sharedPhoto]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let target = try LocalJournalRepository(directory: root()); _ = try target.restoreBackup(from: backup)
        XCTAssertTrue(try target.delete(first.id, expectedRevision: 1).complete)
        XCTAssertEqual(try target.photoData(first.photos[0].id), png)
        XCTAssertNotNil(try target.get(second.id))
        XCTAssertTrue(try target.delete(second.id, expectedRevision: 1).complete)
        XCTAssertThrowsError(try target.photoData(first.photos[0].id))
    }

    #if os(macOS)
    func testActualProcessTerminationBeforeCommitRecoversWithoutPartialRecord() throws {
        let dir = root(), store = try LocalJournalRepository(directory: dir)
        let first = try store.record(draft(photos: true))
        var location = Bundle(for: Self.self).bundleURL
        var executable: URL?
        for _ in 0..<5 {
            let candidate = location.appendingPathComponent("FoxJournalCrashFixture")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
            location.deleteLastPathComponent()
        }
        let process = Process(); process.executableURL = try XCTUnwrap(executable)
        process.arguments = [dir.path]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 86)
        let reopened = try LocalJournalRepository(directory: dir)
        XCTAssertEqual(try reopened.list(), [first]); XCTAssertEqual(try reopened.photoData(first.photos[0].id), png)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("attachments").path).count, 1)
    }
    #endif
}
