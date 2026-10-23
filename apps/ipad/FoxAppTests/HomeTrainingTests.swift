import XCTest
import FoxTrainingCore
@testable import Fox

final class HomeTrainingTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomeTrainingTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("archive.json")
    }
    func testMissingDoesNotCreateArchiveOrDefaultPlan() throws {
        let url = try file()
        let snapshot = try HomeTrainingSnapshot.read(from: url)
        XCTAssertNil(snapshot.plan); XCTAssertNil(snapshot.current); XCTAssertTrue(snapshot.confirmed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testCorruptArchiveIsNotRepairedOrOverwritten() throws {
        let url = try file(), bytes = Data("broken archive".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try HomeTrainingSnapshot.read(from: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testReadingActiveSessionDoesNotRecoverOrPersistIt() throws {
        let url = try file(), date = Date(timeIntervalSince1970: 1_700_000_000)
        var archive = TrainingArchive()
        var session = try TrainingSession(plan: archive.plan, now: date)
        try session.startSet(at: date)
        archive.sessions = [session]
        let bytes = try LocalTrainingRepository.encoder().encode(archive); try bytes.write(to: url)
        for _ in 0..<2 {
            let snapshot = try HomeTrainingSnapshot.read(from: url)
            XCTAssertEqual(snapshot.current?.stage, .active)
            XCTAssertEqual(snapshot.current?.segmentStartedAt, date)
            XCTAssertNil(snapshot.plan?.scheduledDate)
            XCTAssertTrue(snapshot.confirmed.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
    func testConfirmedHistoryUsesRealStatusAndDateOrder() throws {
        let url = try file(), date = Date(timeIntervalSince1970: 1_700_000_000)
        var archive = TrainingArchive()
        for i in 0..<3 {
            var session = try TrainingSession(plan: archive.plan, now: date.addingTimeInterval(Double(i) * 100))
            try session.skip(at: date.addingTimeInterval(Double(i) * 100 + 1))
            try session.endEarly(at: date.addingTimeInterval(Double(i) * 100 + 2))
            try session.confirm(note: "skipped", at: date.addingTimeInterval(Double(i) * 100 + 3))
            archive.sessions.append(session)
        }
        try LocalTrainingRepository.encoder().encode(archive).write(to: url)
        let snapshot = try HomeTrainingSnapshot.read(from: url)
        XCTAssertEqual(snapshot.confirmed.map(\.id), archive.sessions.reversed().prefix(2).map(\.id))
        XCTAssertEqual(snapshot.confirmed.first?.records.first?.status, "skipped")
        XCTAssertNil(snapshot.current)
    }
    @MainActor
    func testDesignVisionStorageUsesInjectedDirectory() throws {
        let url = try file(), directory = url.deletingLastPathComponent().appendingPathComponent("Vision")
        let controller = VisionLabController(diagnosticRoot: url.deletingLastPathComponent().appendingPathComponent("Diagnostics"),
            storageDirectory: directory)
        XCTAssertEqual(controller.reportFileURL.deletingLastPathComponent().standardizedFileURL.pathComponents,
            directory.standardizedFileURL.pathComponents)
        XCTAssertEqual(controller.cameraState, .stopped)
        XCTAssertNil(controller.latest)
    }
    @MainActor
    func testLoadingDistinguishesPendingEmptyAndUnreadableWithoutWriting() async throws {
        let url = try file(), store = HomeTrainingStore(url: url)
        XCTAssertFalse(store.loaded)
        await store.load()
        XCTAssertTrue(store.loaded); XCTAssertNil(store.error); XCTAssertNil(store.snapshot.plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let bytes = Data("corrupt".utf8); try bytes.write(to: url)
        await store.load()
        XCTAssertTrue(store.loaded); XCTAssertNotNil(store.error); XCTAssertNil(store.snapshot.plan)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
