import AVFoundation
import FoxTrainingCore
import Network
import SwiftUI
import XCTest
@testable import Fox

// Deliberately absent from the simulator test inventory. Simulator green cannot satisfy this gate.
#if !targetEnvironment(simulator)
@MainActor
final class DeviceIntegrationTests: XCTestCase {
    private final class NetworkState {
        let monitor = NWPathMonitor()
        var status = "unknown"
        init() {
            monitor.pathUpdateHandler = { [weak self] path in
                let status = path.status == .unsatisfied ? "unsatisfied" : path.status == .satisfied ? "satisfied" : "requiresConnection"
                Task { @MainActor [weak self] in self?.status = status }
            }
            monitor.start(queue: DispatchQueue(label: "fox.test.network"))
        }
    }

    private struct Surface: View {
        @ObservedObject var controller: VisionLabController
        @ObservedObject var output: GuidanceOutputController
        let enabled: Bool
        var body: some View {
            ZStack {
                PosePreview(controller: controller)
                GuidanceCameraOverlay(output: output,
                    imageSize: CGSize(width: controller.latest?.frame.width ?? 720, height: controller.latest?.frame.height ?? 1280), active: enabled)
                VStack { Text("设备并行验收 · 计划节奏测试负载")
                        .padding(8).foregroundStyle(.white).background(.black.opacity(0.7)); Spacer() }
            }.background(.black)
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try VisionDiagnosticArchive.encode(value).write(to: url, options: .atomic)
    }

    func testPhysicalCameraRecordingSpeechAndOverlayInSixControlledRounds() async throws {
        XCTAssertEqual(ProcessInfo.processInfo.environment["FOX_DEVICE_INTEGRATION"], "1", "Explicit physical test opt-in required")
        guard ProcessInfo.processInfo.environment["FOX_DEVICE_INTEGRATION"] == "1" else { return }
        XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .pad)
        XCTAssertEqual(AVCaptureDevice.authorizationStatus(for: .video), .authorized, "Allow Fox camera access before running")
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FoxTrialDeviceRuns").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let network = NetworkState()
        defer { network.monitor.cancel() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let idleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { window.isHidden = true; previousWindow?.makeKey(); UIApplication.shared.isIdleTimerDisabled = idleDisabled }
        let controller = VisionLabController(diagnosticRoot: root.appendingPathComponent("Diagnostics"), storageDirectory: root.appendingPathComponent("IsolatedRecords"))
        XCTAssertEqual(controller.source, .camera, "No fixture or replay permitted")
        defer { controller.stopCamera() }
        let output = GuidanceOutputController(driver: NativeSpeechOutput())
        defer { output.interrupt(reason: "device_test_ended") }
        window.rootViewController = UIHostingController(rootView: Surface(controller: controller, output: output, enabled: false))
        window.makeKeyAndVisible()
        controller.startCamera()
        let warmup = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - warmup < 5 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(controller.cameraState, .running)
        XCTAssertNotNil(controller.latest)
        guard controller.cameraState == .running, controller.latest != nil else { return }
        let offlineRequired = ProcessInfo.processInfo.environment["FOX_DEVICE_OFFLINE_REQUIRED"] == "1"
        if offlineRequired { XCTAssertEqual(network.status, "unsatisfied", "Use USB and disable network for the offline gate") }
        var roundRows: [[String: String]] = []
        struct Condition: Encodable { var time: Double; var active: Bool; var thermal: Int; var orientation: String; var network: String }
        struct Round: Encodable {
            var schema = "fox.trial_device_round.v1"
            var id: String; var mode: String; var round: Int
            var source = "physical_camera"
            var deviceModel: String; var appVersion: String; var appBuild: String
            var camera = "front"; var durationSeconds: Double; var stopReason: String
            var conditions: [Condition]
            var audioRoutes: [String]; var outputVolume: Float; var chineseVoiceIdentifier: String?
            var loadSource = "synthetic_planned_guidance_not_observed_repetitions"
        }
        for number in 1...3 {
            for enabled in [false, true] {
                let mode = enabled ? "on" : "off", id = "\(mode)-\(number)"
                output.interrupt(reason: "round_changed")
                output.setSpeechEnabled(enabled); output.overlayEnabled = enabled
                window.rootViewController = UIHostingController(rootView: Surface(controller: controller, output: output, enabled: enabled))
                try await Task.sleep(nanoseconds: 500_000_000)
                controller.beginTemporaryDiagnostic()
                let diagnosticID = try XCTUnwrap(controller.diagnosticCapture.recordingID)
                let eventOffset = output.events.count
                let begin = ProcessInfo.processInfo.systemUptime
                var conditions: [Condition] = [], lastCondition = -1
                while ProcessInfo.processInfo.systemUptime - begin < 15 {
                    let now = ProcessInfo.processInfo.systemUptime, elapsed = now - begin
                    XCTAssertEqual(controller.cameraState, .running)
                    if Int(elapsed) != lastCondition {
                        lastCondition = Int(elapsed)
                        conditions.append(.init(time: elapsed, active: UIApplication.shared.applicationState == .active,
                            thermal: ProcessInfo.processInfo.thermalState.rawValue,
                            orientation: controller.screenOrientation.rawValue, network: network.status))
                    }
                    output.update(.init(context: .init(sessionID: "device-benchmark", attemptID: id, observationID: id),
                        time: now, stage: .active, exercise: .curl, mode: enabled ? .planned : .off,
                        count: Int(elapsed / 3), targetReps: nil, motion: nil,
                        tempo: [.init("lift", seconds: 1, visual: "expand"), .init("peak", seconds: 0.5, visual: "vibrate"), .init("lower", seconds: 1.5, visual: "shrink")],
                        elapsed: elapsed))
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                output.interrupt(reason: "round_ended")
                controller.finishDiagnostic(reason: "benchmarkComplete")
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while controller.diagnosticCapture.finishing && ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                XCTAssertFalse(controller.diagnosticCapture.finishing)
                let source = controller.diagnosticCapture.draftRoot.appendingPathComponent(diagnosticID.uuidString)
                let manifest = try VisionDiagnosticArchive.decode(VisionDiagnosticManifest.self, at: source.appendingPathComponent("manifest.json"))
                XCTAssertEqual(manifest.state, "complete"); XCTAssertGreaterThan(manifest.video?.encodedFrames ?? 0, 100)
                let folder = root.appendingPathComponent(id)
                try FileManager.default.copyItem(at: source, to: folder)
                let row = Round(id: id, mode: mode, round: number, deviceModel: VisionDiagnosticArchive.hardwareModel(),
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    durationSeconds: ProcessInfo.processInfo.systemUptime - begin, stopReason: manifest.stopReason, conditions: conditions,
                    audioRoutes: AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue },
                    outputVolume: AVAudioSession.sharedInstance().outputVolume,
                    chineseVoiceIdentifier: AVSpeechSynthesisVoice(language: "zh-CN")?.identifier)
                try write(row, to: folder.appendingPathComponent("round.json"))
                let events = Array(output.events.dropFirst(eventOffset))
                try write(events, to: folder.appendingPathComponent("speech.json"))
                if enabled {
                    XCTAssertTrue(events.contains { $0.state == "finished" && $0.outputKind == "system_speech_callback_not_audibility" })
                    XCTAssertFalse(events.contains { $0.state == "failed" })
                } else { XCTAssertFalse(events.contains { $0.state == "started" }) }
                if offlineRequired { XCTAssertTrue(conditions.allSatisfy { $0.network == "unsatisfied" }) }
                // Host tests own this window; XCUIScreen requires unrelated device UI-automation permission.
                // This image checks the overlay only. Use each retained video to review the camera scene.
                let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let screenshot = XCTAttachment(image: image)
                screenshot.name = "device-\(id)"; screenshot.lifetime = .keepAlways; add(screenshot)
                roundRows.append(["id": id])
                try write(["rounds": roundRows], to: root.appendingPathComponent("run.json"))
            }
        }
        let receipt = XCTAttachment(string: root.lastPathComponent)
        receipt.name = "FoxTrialDeviceRuns-directory"; receipt.lifetime = .keepAlways; add(receipt)
        XCTAssertEqual(roundRows.count, 6)
        XCTAssertEqual(output.droppedEvents, 0)
    }
}
#endif
