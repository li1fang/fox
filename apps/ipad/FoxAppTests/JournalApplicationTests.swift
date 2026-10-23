import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import FoxJournalCore
@testable import Fox

@MainActor
final class JournalApplicationTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    private func store(failSaveOnce: Bool = false) -> JournalStore {
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory.appendingPathComponent("Journal"),
            exportDirectory: directory.appendingPathComponent("Exports"), failSaveOnce: failSaveOnce)
    }

    private func checkTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
    private func checkFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }
    private func checkNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(value, file: file, line: line) }
    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32)).pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
        }
    }

    func testPhotoOnlyAndTextPhotoSurviveReopenWithExactBytes() async throws {
        let model = store()
        let photo = try JournalMedia.prepare(png())
        checkTrue(await model.save(photos: [photo]))
        model.note = "买了两块羊排，56 元；尚未吃。"
        checkTrue(await model.save(photos: [photo]))
        let reopened = store()
        await reopened.load()
        XCTAssertEqual(reopened.records.count, 2)
        XCTAssertTrue(reopened.records.contains { $0.note == nil })
        let record = try XCTUnwrap(reopened.records.first { $0.note != nil })
        let data = try await reopened.photoData(record.photos[0].id)
        XCTAssertEqual(data, photo.input.data)
        XCTAssertNil(record.occurred)
    }

    func testFailedSaveRetainsNoteAndRetryDoesNotDuplicate() async throws {
        let model = store(failSaveOnce: true)
        let photo = try JournalMedia.prepare(png())
        model.note = "今天感觉不错"
        checkFalse(await model.save(photos: [photo]))
        XCTAssertEqual(model.note, "今天感觉不错")
        XCTAssertNotNil(model.saveError)
        checkTrue(await model.save(photos: [photo]))
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.note, "")
        checkFalse(await model.save())
        let reopened = store(); await reopened.load()
        XCTAssertEqual(reopened.records.count, 1)
    }

    func testConcurrentSaveRequestsCreateOneRecord() async {
        let model = store(); model.note = "只保存一次"
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { await model.save() } }
            for await _ in group {}
        }
        let reopened = store(); await reopened.load()
        XCTAssertEqual(reopened.records.count, 1)
    }

    func testImageLoadCancelFailureAndInvalidBytesKeepExistingPhoto() async throws {
        let selection = JournalPhotoSelection()
        let bytes = png()
        await selection.load { bytes }
        let id = try XCTUnwrap(selection.items.first?.id)
        await selection.load { nil }
        XCTAssertEqual(selection.items.first?.id, id)
        await selection.load { throw CocoaError(.fileReadNoSuchFile) }
        XCTAssertEqual(selection.items.count, 1)
        XCTAssertNotNil(selection.error)
        await selection.load { Data("not an image".utf8) }
        XCTAssertEqual(selection.items.first?.id, id)
        XCTAssertNotNil(selection.error)
        XCTAssertFalse(selection.loading)
    }

    func testRevisionPreservesOriginalAndRejectsStaleEdit() async throws {
        let model = store(); model.note = "买了羊排"
        let photo = try JournalMedia.prepare(png())
        checkTrue(await model.save(photos: [photo]))
        let original = try XCTUnwrap(model.records.first)
        let edited = await model.revise(original, note: "买了两块羊排", keepPhotoIDs: original.photos.map(\.id), photos: [])
        XCTAssertEqual(edited?.revision, 2)
        XCTAssertEqual(edited?.recordedAt, original.recordedAt)
        let rejected = await model.revise(original, note: "过期更正", keepPhotoIDs: [], photos: [])
        XCTAssertNil(rejected)
        XCTAssertTrue(model.revisionConflict)
        let repository = try LocalJournalRepository(directory: directory.appendingPathComponent("Journal"))
        XCTAssertEqual(try repository.history(original.id).map(\.note), ["买了羊排", "买了两块羊排"])
        XCTAssertEqual(try repository.photoData(original.photos[0].id), photo.input.data)
    }

    func testBackupRoundTripAndDuplicateRestorePreserveHistoryAndPhotos() async throws {
        let model = store(); model.note = "起床了"
        let photo = try JournalMedia.prepare(png())
        checkTrue(await model.save(photos: [photo]))
        let original = try XCTUnwrap(model.records.first)
        _ = await model.revise(original, note: "起床，感觉头疼", keepPhotoIDs: original.photos.map(\.id), photos: [])
        let backup = try unwrap(await model.prepareBackup())
        let restored = JournalStore(directory: directory.appendingPathComponent("Restored"),
            exportDirectory: directory.appendingPathComponent("OtherExports"))
        let first = await restored.restoreBackup(from: backup.url)
        XCTAssertEqual(first?.inserted, 1)
        let again = await restored.restoreBackup(from: backup.url)
        XCTAssertEqual(again?.unchanged, 1)
        XCTAssertEqual(restored.records.first?.note, "起床，感觉头疼")
        let data = try await restored.photoData(original.photos[0].id)
        XCTAssertEqual(data, photo.input.data)
        let repo = try LocalJournalRepository(directory: directory.appendingPathComponent("Restored"))
        XCTAssertEqual(try repo.history(original.id).count, 2)
    }

    func testBrokenBackupAndConflictNeverOverwriteExistingRecordsOrDraft() async throws {
        let model = store(); model.note = "原记录"; _ = await model.save()
        let original = try XCTUnwrap(model.records.first)
        let backup = try unwrap(await model.prepareBackup())
        _ = await model.revise(original, note: "已更正", keepPhotoIDs: [], photos: [])
        model.note = "尚未保存的输入"
        checkNil(await model.restoreBackup(from: backup.url))
        XCTAssertEqual(model.records.first?.note, "已更正")
        XCTAssertEqual(model.note, "尚未保存的输入")
        try Data("broken".utf8).write(to: backup.url.appendingPathComponent("manifest.json"))
        checkNil(await model.restoreBackup(from: backup.url))
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.note, "尚未保存的输入")
    }

    func testDeleteChecksRevisionAndRemovesOnlySelectedRecord() async throws {
        let model = store(); model.note = "第一条"; _ = await model.save()
        let first = try XCTUnwrap(model.records.first)
        model.note = "第二条"; _ = await model.save()
        let revised = try unwrap(await model.revise(first, note: "第一条更正", keepPhotoIDs: [], photos: []))
        checkFalse(await model.delete(first))
        checkTrue(await model.delete(revised))
        XCTAssertEqual(model.records.map(\.note), ["第二条"])
    }

    func testCancelledBackupOnlyRemovesTemporaryExportAndKeepsDraft() async throws {
        let model = store(); model.note = "已保存"; _ = await model.save()
        model.note = "未提交"
        let backup = try unwrap(await model.prepareBackup())
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.url.path))
        await model.discardBackup(backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.url.path))
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.note, "未提交")
    }

    func testPaginationCanReadBeyondOneThousandWithoutDuplicates() async throws {
        let model = store()
        let repo = try LocalJournalRepository(directory: directory.appendingPathComponent("Journal"))
        for index in 0..<1003 { _ = try repo.record(CaptureDraft(note: "条目 \(index)")) }
        await model.load()
        while model.canLoadMore { await model.load(more: true) }
        XCTAssertEqual(model.records.count, 1003)
        XCTAssertEqual(Set(model.records.map(\.id)).count, 1003)
    }

    func testPhotoRemovalKeepsHistoryButRejectsAnEmptyRecord() async throws {
        let model = store()
        let photo = try JournalMedia.prepare(png())
        _ = await model.save(photos: [photo])
        let original = try unwrap(model.records.first)
        checkNil(await model.revise(original, note: "", keepPhotoIDs: [], photos: []))
        let edited = try unwrap(await model.revise(original, note: "已移除当前照片", keepPhotoIDs: [], photos: []))
        XCTAssertTrue(edited.photos.isEmpty)
        let repo = try LocalJournalRepository(directory: directory.appendingPathComponent("Journal"))
        XCTAssertEqual(try repo.history(original.id).first?.photos.count, 1)
        XCTAssertEqual(try repo.photoData(original.photos[0].id), photo.input.data)
    }

    func testJPEGOrientationOnlyTransformsThumbnailNotOriginalBytes() throws {
        let image = try unwrap(UIImage(data: png())?.cgImage)
        let bytes = NSMutableData()
        let destination = try unwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prepared = try JournalMedia.prepare(bytes as Data)
        XCTAssertEqual(prepared.input.data, bytes as Data)
        XCTAssertEqual(prepared.input.mimeType, "image/jpeg")
        let preview = try unwrap(UIImage(data: prepared.thumbnail))
        XCTAssertGreaterThan(preview.size.width, preview.size.height)
    }

    func testExportFailureAndUnsafeCleanupDoNotDeleteDataOrDraft() async throws {
        let model = store(); model.note = "原记录"; _ = await model.save()
        model.note = "当前草稿"
        let blocked = directory.appendingPathComponent("Exports")
        try Data("not a directory".utf8).write(to: blocked)
        checkNil(await model.prepareBackup())
        XCTAssertNotNil(model.operationError)
        XCTAssertEqual(model.note, "当前草稿")
        XCTAssertEqual(model.records.count, 1)
        let id = UUID()
        let outside = directory.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        await model.discardBackup(PreparedJournalBackup(id: id, url: outside.appendingPathComponent("foreign"), records: 0, photos: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testUnreadableLegacyPhotoStillAllowsTextAndBackup() async throws {
        let model = store()
        let repo = try LocalJournalRepository(directory: directory.appendingPathComponent("Journal"))
        let record = try repo.record(CaptureDraft(note: "原文保留", photos: [PhotoInput(data: Data([1, 2, 3]), mimeType: "image/png")]))
        await model.load()
        do { _ = try await model.thumbnail(record.photos[0].id); XCTFail("Invalid pixels must not become a preview") }
        catch {}
        XCTAssertEqual(model.records.first?.note, "原文保留")
        let backup = await model.prepareBackup()
        XCTAssertNotNil(backup)
    }
}
