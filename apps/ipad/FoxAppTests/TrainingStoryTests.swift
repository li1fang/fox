import FoxTrainingCore
import XCTest
@testable import Fox

@MainActor
final class TrainingStoryTests: XCTestCase {
    func testPreparationAndRecoveryExplainRetainedFactsWithoutInventingMotion() {
        let waiting = VisionTaskMessage(start: .waiting, subject: .waiting, tracking: .acquiring, counting: false, hasTrial: false, count: 0)
        XCTAssertTrue(waiting.detail.contains("肩肘"))
        XCTAssertFalse(waiting.detail.contains("全身"))
        XCTAssertFalse(waiting.detail.contains("已记"))
        XCTAssertFalse(waiting.allowsPlannedTempo)
        for start in [PoseStartState.waiting, .countdown(2)] {
            let recovery = VisionTaskMessage(start: start, subject: .bound, tracking: .lost, counting: false, hasTrial: true, count: 3)
            XCTAssertTrue(recovery.detail.contains("已记 3 次保留"))
            XCTAssertFalse(recovery.detail.contains("重新就位"), "An armed recovery must not ask for another tap")
            XCTAssertFalse(recovery.allowsPlannedTempo)
        }
        let gap = VisionTaskMessage(start: .idle, subject: .occluded, tracking: .grace, counting: true, hasTrial: true, count: 3)
        XCTAssertTrue(gap.detail.contains("等待恢复"))
        XCTAssertTrue(gap.detail.contains("已记 3 次保留"))
        XCTAssertFalse(gap.allowsPlannedTempo)
        let lost = VisionTaskMessage(start: .idle, subject: .lost, tracking: .lost, counting: true, hasTrial: true, count: 3)
        XCTAssertTrue(lost.detail.contains("重新就位"))
        XCTAssertFalse(lost.detail.contains("秒"))
        XCTAssertFalse(lost.allowsPlannedTempo)
        let paused = VisionTaskMessage(start: .idle, subject: .lost, tracking: .lost, counting: false, hasTrial: true, count: 3)
        XCTAssertTrue(paused.detail.contains("就位后继续"))
        XCTAssertFalse(paused.allowsPlannedTempo)
        let observed = VisionTaskMessage(start: .ready, subject: .bound, tracking: .tracking, counting: true, hasTrial: true, count: 3)
        XCTAssertTrue(observed.allowsPlannedTempo)
    }

    func testReferenceIsOptionalAndCannotAcceptInvalidOrNegativeCounts() {
        for value in ["", "0", "3", "10000"] { XCTAssertTrue(VisionReportInput.validReference(value), value) }
        for value in ["-1", "10001", "1.5", "abc", " "] { XCTAssertFalse(VisionReportInput.validReference(value), value) }
    }

    func testCameraLayoutReservesActionsInPhonePadAndExpandedSizes() {
        for size in [CGSize(width: 378, height: 680), CGSize(width: 760, height: 330),
                     CGSize(width: 778, height: 890), CGSize(width: 1130, height: 650), CGSize(width: 760, height: 720)] {
            let bounds = CGRect(origin: .zero, size: size)
            let layout = PhoneCameraLayout(landscape: size.width > 840 || size.height < 400)
            let slots = layout.regions(in: bounds, informationHeight: 220, actionsHeight: 60)
            for slot in [slots.information, slots.camera, slots.actions] {
                XCTAssertTrue(bounds.contains(slot)); XCTAssertGreaterThan(slot.height, 0)
            }
            XCTAssertFalse(slots.actions.intersects(slots.camera))
            XCTAssertFalse(slots.actions.intersects(slots.information))
        }
    }

    func testVideoDispositionChangesOnlyAfterSuccessfulChoiceAndIsScopedToCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VisionDiagnosticStore(root: root.appendingPathComponent("Retained"))
        func context() -> VisionDiagnosticContext {
            VisionDiagnosticContext(source: .fixture, device: "fixture", appVersion: "test", appBuild: "test", camera: "front",
                exercise: .curl, arm: .left, bodyView: .side, screenOrientation: .portrait,
                configuration: .standard, runtimePolicy: .standard)
        }
        let first = context()
        XCTAssertTrue(store.begin(first))
        let folder = try VisionDiagnosticArchive.prepare(first, root: store.draftRoot)
        let manifest = try VisionDiagnosticArchive.seal(context: first, folder: folder, state: "failed", reason: "noVideo", error: nil, video: nil)
        store.receive(id: first.id, result: .success(manifest))
        XCTAssertTrue(store.status.contains("待核对"))
        let kept = await store.retain(manifest)
        XCTAssertTrue(kept); XCTAssertTrue(store.status.contains("已保留"))
        XCTAssertTrue(store.status.contains("无完整视频"))
        store.remove(manifest)
        for _ in 0..<100 where !store.status.contains("已删除") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.status.contains("已删除"))
        let second = context()
        XCTAssertTrue(store.begin(second))
        XCTAssertFalse(store.status.contains("已保留"))
        store.receive(id: second.id, result: .failure(VisionDiagnosticArchive.error("failed")))
        XCTAssertTrue(store.status.contains("不可用"))
        let discardedOld = await store.discard(manifest)
        XCTAssertFalse(discardedOld)
        XCTAssertTrue(store.status.contains("不可用"), "A choice for an older package cannot label the current recording")
        let third = context()
        XCTAssertTrue(store.begin(third))
        let thirdFolder = try VisionDiagnosticArchive.prepare(third, root: store.draftRoot)
        let thirdManifest = try VisionDiagnosticArchive.seal(context: third, folder: thirdFolder, state: "failed", reason: "noVideo", error: nil, video: nil)
        store.receive(id: third.id, result: .success(thirdManifest))
        let discarded = await store.discard(thirdManifest)
        XCTAssertTrue(discarded)
        XCTAssertTrue(store.status.contains("已丢弃"))
        let fourth = context()
        XCTAssertTrue(store.begin(fourth))
        let fourthFolder = try VisionDiagnosticArchive.prepare(fourth, root: store.draftRoot)
        let pending = try VisionDiagnosticArchive.seal(context: fourth, folder: fourthFolder, state: "failed", reason: "noVideo", error: nil, video: nil)
        store.receive(id: fourth.id, result: .success(pending))
        for _ in 0..<100 where store.drafts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.reviewCandidate?.id, fourth.id)
        let fifth = context()
        XCTAssertTrue(store.begin(fifth))
        store.receive(id: fifth.id, result: .failure(VisionDiagnosticArchive.error("failed")))
        XCTAssertFalse(store.drafts.isEmpty)
        XCTAssertNil(store.reviewCandidate, "An older pending package must not be presented as this failed capture")
        let reopened = VisionDiagnosticStore(root: store.root)
        for _ in 0..<100 where reopened.drafts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(reopened.latestCaptureID)
        XCTAssertEqual(reopened.reviewCandidate?.id, fourth.id, "Old drafts remain reachable after restart, without a current-capture label")
    }
}
