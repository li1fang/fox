import AVFoundation
import FoxTrainingCore
import SwiftUI
import XCTest
@testable import Fox

@MainActor
final class PhoneCameraLayoutTests: XCTestCase {
    func testVisionPageRetainsPreviewAcrossSizeClassChanges() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = VisionLabController(diagnosticRoot: root.appendingPathComponent("Diagnostics"), storageDirectory: root)
        defer { controller.stopCamera(); try? FileManager.default.removeItem(at: root) }
        let host = UIHostingController(rootView: VisionLabView(controller: controller).environment(\.verticalSizeClass, .regular))
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 200_000_000)
        let original = try XCTUnwrap(previews(in: host.view).first)
        for sizeClass in [UserInterfaceSizeClass.compact, .regular, .compact] {
            host.rootView = VisionLabView(controller: controller).environment(\.verticalSizeClass, sizeClass)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            let current = try XCTUnwrap(previews(in: host.view).first)
            XCTAssertTrue(original === current, "Rotation must not recreate/reattach the capture preview")
            XCTAssertEqual(previews(in: host.view).count, 1)
        }
    }

    func testWorkoutRetainsPreviewAcrossSizeClassChanges() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TrainingStore(archiveURL: root.appendingPathComponent("training.json"), diagnosticRoot: root.appendingPathComponent("Diagnostics"))
        store.prepareDay1Draft(); store.start()
        let session = try XCTUnwrap(store.session)
        XCTAssertNotNil(session.exercise.visualObservation)
        let host = UIHostingController(rootView: TrainingScreen(store: store, session: session, onConfirmed: {}).environment(\.verticalSizeClass, .regular))
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true; store.workoutVision.stop(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let original = try XCTUnwrap(previews(in: host.view).first)
        for sizeClass in [UserInterfaceSizeClass.compact, .regular, .compact] {
            host.rootView = TrainingScreen(store: store, session: session, onConfirmed: {}).environment(\.verticalSizeClass, sizeClass)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertTrue(original === previews(in: host.view).first, "Workout rotation must retain the preview")
        }
    }

    private func previews(in view: UIView) -> [PosePreviewView] {
        (view as? PosePreviewView).map { [$0] } ?? view.subviews.flatMap { previews(in: $0) }
    }

    func testRepeatedFrameLayoutsReportOrientationOnlyWhenItChanges() {
        let view = PosePreviewView()
        view.fixture = true
        var orientations: [VisionScreenOrientation] = []
        view.onScreenOrientation = { orientations.append($0) }
        for interface in [UIInterfaceOrientation.portrait, .landscapeLeft, .landscapeRight, .portrait] {
            for _ in 0..<100 { view.updateInterfaceOrientation(interface) }
        }
        XCTAssertEqual(orientations, [.portrait, .landscapeLeft, .landscapeRight, .portrait])
    }

    func testSettingsCameraSelectionDoesNotRestartHiddenPreview() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = VisionLabController(diagnosticRoot: root.appendingPathComponent("Diagnostics"), storageDirectory: root)
        defer { controller.stopCamera(); try? FileManager.default.removeItem(at: root) }
        controller.changeCamera(false, restartPreview: false)
        XCTAssertFalse(controller.frontCamera)
        XCTAssertEqual(controller.cameraState, .stopped)
        controller.changeCamera(true, restartPreview: false)
        XCTAssertTrue(controller.frontCamera)
        XCTAssertEqual(controller.cameraState, .stopped)
    }

    func testPhoneRegionsKeepCameraAndActionsSeparateInBothOrientations() {
        for bounds in [CGRect(x: 12, y: 8, width: 378, height: 720), CGRect(x: 12, y: 12, width: 730, height: 330)] {
            let landscape = bounds.width > bounds.height
            let regions = PhoneCameraLayout(landscape: landscape).regions(in: bounds, informationHeight: 170, actionsHeight: 100)
            for region in [regions.information, regions.camera, regions.actions] {
                XCTAssertTrue(bounds.contains(region))
                XCTAssertFalse(region.isEmpty)
            }
            XCTAssertFalse(regions.camera.intersects(regions.information))
            XCTAssertFalse(regions.camera.intersects(regions.actions))
            XCTAssertFalse(regions.information.intersects(regions.actions))
            if landscape { XCTAssertEqual(regions.camera.height, bounds.height) }
            else { XCTAssertEqual(regions.camera.width, bounds.width) }
        }
    }

    func testPreviewKeepsAspectFitAndFixtureRequiresBothTestingAndFixtureSource() {
        let view = PosePreviewView()
        XCTAssertEqual(view.preview.videoGravity, .resizeAspect)
        XCTAssertFalse(PosePreviewView.allowsFramingImage(environment: [:], fixture: true))
        XCTAssertFalse(PosePreviewView.allowsFramingImage(environment: ["FOX_POSE_IMAGE_FIXTURE": "1"], fixture: true))
        let testing = ["FOX_UI_TESTING": "1", "FOX_POSE_IMAGE_FIXTURE": "1"]
        XCTAssertFalse(PosePreviewView.allowsFramingImage(environment: testing, fixture: false))
        XCTAssertTrue(PosePreviewView.allowsFramingImage(environment: testing, fixture: true))
    }

    func testAllImageCornersStayInPortraitAndLandscapeContainersWithMatchingProjection() {
        for image in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720)] {
            let bitmap = PosePreviewView.makeFramingImage(size: image)
            XCTAssertEqual(bitmap.size, image)
            for container in [CGSize(width: 378, height: 580), CGSize(width: 742, height: 160)] {
                let fit = AVMakeRect(aspectRatio: image, insideRect: CGRect(origin: .zero, size: container))
                for mirrored in [false, true] {
                    for (x, y) in [(0.0, 0.0), (1, 0), (0, 1), (1, 1)] {
                        let point = PosePoint(x: x, y: y, confidence: 1)
                        let result = PoseGeometry.project(point, imageWidth: image.width, imageHeight: image.height,
                            viewWidth: container.width, viewHeight: container.height, mirrored: mirrored)
                        XCTAssertEqual(result.x, (mirrored ? 1 - x : x) * fit.width + fit.minX, accuracy: 0.001)
                        XCTAssertEqual(result.y, (1 - y) * fit.height + fit.minY, accuracy: 0.001)
                        XCTAssertTrue(CGRect(origin: .zero, size: container).insetBy(dx: -0.01, dy: -0.01).contains(CGPoint(x: result.x, y: result.y)))
                    }
                }
            }
        }
    }
}
