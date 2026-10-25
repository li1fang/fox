import FoxTrainingCore
import SwiftUI
import XCTest
@testable import Fox

@MainActor
final class AdaptiveLayoutTests: XCTestCase {
    func testSpacePolicyPreservesPhoneAndPadWhileExpandingDuo() {
        XCTAssertFalse(FoxAdaptiveLayout.sideBySide(horizontal: .compact, vertical: .regular))
        XCTAssertTrue(FoxAdaptiveLayout.sideBySide(horizontal: .regular, vertical: .regular))
        XCTAssertTrue(FoxAdaptiveLayout.sideBySide(horizontal: .compact, vertical: .compact))
        XCTAssertEqual(FoxAdaptiveLayout.columns(width: 760, phone: true, horizontal: .regular, vertical: .regular, accessibility: false), 2)
        XCTAssertEqual(FoxAdaptiveLayout.columns(width: 850, phone: true, horizontal: .regular, vertical: .compact, accessibility: false), 1)
        XCTAssertEqual(FoxAdaptiveLayout.columns(width: 390, phone: true, horizontal: .compact, vertical: .regular, accessibility: false), 1)
        XCTAssertEqual(FoxAdaptiveLayout.columns(width: 1100, phone: false, horizontal: .regular, vertical: .regular, accessibility: false), 3)
        XCTAssertEqual(FoxAdaptiveLayout.columns(width: 1100, phone: true, horizontal: .regular, vertical: .regular, accessibility: true), 1)
    }

    func testFoldAndCameraRegionsDoNotCoverUsableContent() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 760)
        XCTAssertEqual(FoxAdaptiveLayout.usableRect(in: bounds, avoiding: []), bounds)
        for cuts in [[CGRect(x: 390, y: 0, width: 20, height: 760)],
                     [CGRect(x: 0, y: 370, width: 800, height: 20)],
                     [CGRect(x: 390, y: 0, width: 20, height: 760), CGRect(x: 600, y: 0, width: 40, height: 40)]] {
            let area = FoxAdaptiveLayout.usableRect(in: bounds, avoiding: cuts)
            XCTAssertTrue(bounds.contains(area)); XCTAssertGreaterThan(area.width, 300); XCTAssertGreaterThan(area.height, 300)
            for cut in cuts { XCTAssertFalse(area.intersects(cut)) }
        }
        XCTAssertEqual(FoxAdaptiveLayout.usableRect(in: bounds, avoiding: [.zero, .null]), bounds)
        XCTAssertEqual(FoxAdaptiveLayout.usableRect(in: bounds, avoiding: [bounds]), .zero)
    }

    func testExpandedPhoneKeepsPreviewIdentityAndUsesSideBySideSpace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = VisionLabController(diagnosticRoot: root.appendingPathComponent("Diagnostics"), storageDirectory: root)
        defer { controller.stopCamera(); try? FileManager.default.removeItem(at: root) }
        let host = UIHostingController(rootView: VisionLabView(controller: controller)
            .environment(\.horizontalSizeClass, .compact).environment(\.verticalSizeClass, .regular))
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        let original = try XCTUnwrap(previews(host.view).first)
        for width in [760.0, 820.0, 760.0] {
            host.rootView = VisionLabView(controller: controller)
                .environment(\.horizontalSizeClass, .regular).environment(\.verticalSizeClass, .regular)
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: 780)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            let preview = try XCTUnwrap(previews(host.view).first)
            XCTAssertTrue(original === preview)
            XCTAssertEqual(previews(host.view).count, 1)
            let frame = preview.convert(preview.bounds, to: host.view)
            XCTAssertGreaterThan(frame.minX, 200, "Expanded phone must place controls beside, not above, its preview")
            XCTAssertGreaterThan(frame.height, 600)
        }
    }

    func testTrainingResizePreservesSessionArchiveAndPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("training.json")
        let store = TrainingStore(archiveURL: file, diagnosticRoot: root.appendingPathComponent("Diagnostics"))
        store.prepareDay1Draft(); store.start()
        let session = try XCTUnwrap(store.session), before = try Data(contentsOf: file)
        let host = UIHostingController(rootView: TrainingScreen(store: store, session: session, onConfirmed: {})
            .environment(\.horizontalSizeClass, .compact).environment(\.verticalSizeClass, .regular))
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; store.workoutVision.stop(); try? FileManager.default.removeItem(at: root) }
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 780); host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        let preview = try XCTUnwrap(previews(host.view).first)
        for size in [CGSize(width: 760, height: 780), CGSize(width: 390, height: 780), CGSize(width: 820, height: 380)] {
            host.rootView = TrainingScreen(store: store, session: session, onConfirmed: {})
                .environment(\.horizontalSizeClass, size.width > 600 ? .regular : .compact)
                .environment(\.verticalSizeClass, size.height < 440 ? .compact : .regular)
            host.view.frame = CGRect(origin: .zero, size: size); host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertTrue(preview === previews(host.view).first)
            XCTAssertEqual(store.session?.id, session.id)
            XCTAssertEqual(store.session?.stage, session.stage)
            XCTAssertEqual(try Data(contentsOf: file), before, "Layout must not write training facts")
        }
    }

    func testPhysicalCameraChangeBreaksContinuityOnlyOnce() {
        var continuity = CameraSourceContinuity()
        XCTAssertFalse(continuity.changed(to: "outer"))
        XCTAssertFalse(continuity.changed(to: "outer"))
        XCTAssertTrue(continuity.changed(to: "inner"))
        XCTAssertFalse(continuity.changed(to: "inner"))
        XCTAssertTrue(continuity.changed(to: "outer"))
        continuity = CameraSourceContinuity()
        XCTAssertFalse(continuity.changed(to: "inner"))
    }

    private func previews(_ view: UIView) -> [PosePreviewView] {
        (view as? PosePreviewView).map { [$0] } ?? view.subviews.flatMap(previews)
    }
}
