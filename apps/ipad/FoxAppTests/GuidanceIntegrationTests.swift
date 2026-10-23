import AVFoundation
import XCTest
import FoxTrainingCore
@testable import Fox

@MainActor
final class GuidanceIntegrationTests: XCTestCase {
    private final class Driver: SpeechOutputDriver {
        var onEvent: ((String, SpeechPlaybackEvent) -> Void)?
        var cues: [GuidanceCue] = []
        func speak(_ cue: GuidanceCue) -> Bool { cues.append(cue); onEvent?(cue.id, .started); onEvent?(cue.id, .finished); return true }
        func stop() {}
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guidance-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testHeadphoneRemovalMutesUntilExplicitReenable() throws {
        let root = try directory()
        let controller = VisionLabController(diagnosticRoot: root.appendingPathComponent("diagnostics"), storageDirectory: root)
        let guidance = GuidanceSession(vision: controller, driver: Driver(), defaults: nil)
        XCTAssertTrue(guidance.output.speechEnabled)
        guidance.audioRouteChanged(.oldDeviceUnavailable)
        XCTAssertFalse(guidance.output.speechEnabled)
        guidance.sample()
        guidance.audioRouteChanged(.newDeviceAvailable)
        XCTAssertFalse(guidance.output.speechEnabled, "A later sample or new route must not implicitly enable speech")
        guidance.setSpeech(true)
        XCTAssertTrue(guidance.output.speechEnabled)
    }

    func testStandaloneGuidanceReadsActualControllerWithoutTakingItsCallbacks() throws {
        let root = try directory()
        let controller = VisionLabController(diagnosticRoot: root.appendingPathComponent("diagnostics"), storageDirectory: root)
        let clock = VisionReplayClock(); controller.enableReplay(clock: clock)
        let driver = Driver(), guidance = GuidanceSession(vision: controller, driver: Driver(), defaults: nil)
        let spoken = GuidanceSession(vision: controller, driver: driver, defaults: nil)
        var callbackCount = 0
        controller.onCountingUpdated = { callbackCount += 1 }
        controller.startCamera(); controller.startCounting()
        defer { controller.stopCamera(); guidance.stop(); spoken.stop() }
        func send(_ angle: Double, at time: Double) {
            clock.uptime = 1000 + time
            let radians = angle * .pi / 180
            let body = BodyPose(points: [.leftShoulder: .init(x: 0.48, y: 0.8),
                .leftElbow: .init(x: 0.48, y: 0.55),
                .leftWrist: .init(x: 0.48 + sin(radians) * 0.22 * 720 / 1280, y: 0.55 + cos(radians) * 0.22)])
            let frame = PoseFrame(timestamp: time, width: 1280, height: 720, people: [body])
            controller.replayFrame(CapturedPose(frame: frame, latencyMs: 1, revision: 1, cameraGeometry: nil))
            guidance.sample(); spoken.sample()
        }
        for i in 0...36 { send(160, at: Double(i) / 10) }
        let cycle = [160.0,160,160,160,160,140,120,100,80,55,55,55,55,75,100,100,120,120,140,140,160,160,160,160,160,160]
        for i in cycle.indices { send(cycle[i], at: 3.7 + Double(i) / 10) }
        XCTAssertGreaterThan(callbackCount, 0)
        XCTAssertEqual(controller.automaticCount, 1)
        XCTAssertEqual(driver.cues.filter { $0.kind == .count }.count, 1)
        XCTAssertEqual(driver.cues.first { $0.kind == .count }?.text, "1")
        controller.correct(by: 1)
        clock.uptime += 0.1; spoken.sample()
        XCTAssertEqual(controller.confirmedCount, 2)
        XCTAssertEqual(driver.cues.filter { $0.kind == .count }.count, 1, "Manual correction must not be announced as observed motion")
    }

    func testOverlaySizingStaysInsideTheFullAspectImage() {
        for viewport in [CGSize(width: 390, height: 540), CGSize(width: 500, height: 290), CGSize(width: 1024, height: 700)] {
            for image in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720)] {
                let rect = GuidanceOverlayGeometry.imageRect(image: image, viewport: viewport)
                XCTAssertEqual(rect.width / rect.height, image.width / image.height, accuracy: 0.0001)
                XCTAssertLessThanOrEqual(rect.maxX, viewport.width + 0.0001)
                XCTAssertLessThanOrEqual(rect.maxY, viewport.height + 0.0001)
                XCTAssertEqual(rect.midX, viewport.width / 2, accuracy: 0.0001)
                XCTAssertEqual(rect.midY, viewport.height / 2, accuracy: 0.0001)
            }
        }
    }
}
