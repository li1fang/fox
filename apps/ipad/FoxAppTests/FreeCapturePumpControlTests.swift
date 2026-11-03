import XCTest
import PumpCore
import FoxTrainingCore
@testable import Fox

@MainActor final class FreeCapturePumpControlTests: XCTestCase {
    private func setup() throws -> (URL, PumpSimulatedTransport, PumpCaptureRuntime, FreeCaptureController) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PumpCapture-\(UUID())")
        let defaults = UserDefaults(suiteName: "PumpCapture-\(UUID())")!
        let driver = PumpSimulatedTransport()
        let pump = PumpCaptureRuntime(root: root.appendingPathComponent("Pump"), defaults: defaults, transport: driver)
        let backend = FreeCaptureNativeBackend(root: root.appendingPathComponent("Captures"), fixture: "no_people", pump: pump)
        let controller = FreeCaptureController(backend: backend)
        controller.changePump(enabled: true); pump.scan()
        pump.select(PumpSimulatedTransport.deviceA); pump.select(PumpSimulatedTransport.deviceB)
        return (root, driver, pump, controller)
    }
    private func wait(_ predicate: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(8)
        while Date() < end { if predicate() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("Timed out waiting for capture outcome")
    }
    private func attachPackage(_ package: FreeCapturePackageSummary, name: String) throws {
        var files: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: package.folder.path) {
            files[file] = try Data(contentsOf: package.folder.appendingPathComponent(file)).base64EncodedString()
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: files, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testAllModesAndMaximumAreDraftOnlyUntilOneConfirmedRequest() async throws {
        let (root, driver, pump, _) = try setup()
        defer { pump.shutdown(); try? FileManager.default.removeItem(at: root) }
        for mode in PumpMode.allCases {
            pump.mode = mode; pump.kgText = "20.0"; pump.reduction = [.eccentric, .concentric].contains(mode) ? 25 : 0
            XCTAssertNotNil(pump.configuration); pump.prepareConfirmation()
            let request = try XCTUnwrap(pump.confirmation)
            XCTAssertTrue(driver.writes.isEmpty); XCTAssertEqual(request.configuration.kg, 20)
            pump.confirmation = nil
        }
        pump.mode = .standard; pump.reduction = 0; pump.kgText = "2"
        pump.prepareConfirmation(); await pump.applyConfirmed(try XCTUnwrap(pump.confirmation))
        XCTAssertEqual(driver.writes.count, 2)
        XCTAssertEqual(pump.session?.lastResult?.status, .bothAcknowledgedUnverified)
        pump.mode = .eccentric; XCTAssertNil(pump.configuration)
        pump.kgText = "5"; pump.reduction = 25; XCTAssertNotNil(pump.configuration)
        pump.mode = .standard; XCTAssertNil(pump.configuration)
        pump.reduction = 0; XCTAssertNotNil(pump.configuration)
    }
    func testConfigureRecordSaveAndReconfigureKeepsConnectionAndSelfContainedContext() async throws {
        let (root, driver, pump, controller) = try setup()
        defer { controller.stop(reason: "testCleanup"); pump.shutdown(); try? FileManager.default.removeItem(at: root) }
        let session = try XCTUnwrap(pump.session)
        let request = try session.makeRequest(.init(mode: .standard, kg: 2))
        _ = try await session.applyConfiguration(request)
        controller.start(); try await wait { controller.encodedFrames >= 3 }
        XCTAssertTrue(session.captureID != nil)
        do { _ = try await session.applyConfiguration(request); XCTFail("recording control") } catch {}
        XCTAssertEqual(driver.writes.count, 2)
        controller.stop(reason: "userStopped")
        try await wait { controller.phase == .finished }
        XCTAssertNil(session.captureID)
        XCTAssertTrue(session.selected.allSatisfy { $0.state == "connected" })
        let package = try XCTUnwrap(controller.latest)
        let context = try JSONDecoder().decode(PumpCaptureContext.self, from: Data(contentsOf: package.folder.appendingPathComponent("pump-context.json")))
        XCTAssertEqual(context.captureID, package.id.uuidString)
        XCTAssertEqual(context.devices.count, 2)
        XCTAssertTrue(context.events.contains { $0.requestID == request.id && $0.kind == "configuration_requested" })
        let manifest = try JSONDecoder().decode(LabCaptureManifest.self, from: Data(contentsOf: package.folder.appendingPathComponent("manifest.json")))
        try manifest.validate()
        XCTAssertEqual(manifest.schema, "fox.lab_capture.v1")
        XCTAssertTrue(manifest.files.contains { $0.path == "pump-control.jsonl" })
        try attachPackage(package, name: "native-pump-capture-package")
        let allowed = Set(["discovering", "subscribed_no_data", "receiving", "disconnected", "failed"])
        for name in ["pump-A.jsonl", "pump-B.jsonl"] {
            for line in try String(contentsOf: package.folder.appendingPathComponent(name)).split(separator: "\n") {
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                if let state = row["state"] as? String { XCTAssertTrue(allowed.contains(state), "Noncanonical raw connection state: \(state)") }
                if row["state"] as? String == "disconnected" { XCTAssertNotNil(row["reason"]) }
            }
        }
        let requested = try XCTUnwrap(context.events.first { $0.kind == "configuration_requested" })
        XCTAssertLessThan(try XCTUnwrap(UInt64(requested.hostReceivedNS)), try XCTUnwrap(UInt64(manifest.startedHostNS)))
        _ = try await session.applyConfiguration(session.makeRequest(.init(mode: .eccentric, kg: 5, reduction: 25)))
        XCTAssertEqual(driver.writes.count, 4)
        let bytes = try Data(contentsOf: package.folder.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try FreeCaptureArchive.list(root: root.appendingPathComponent("Captures")).count, 1)
        XCTAssertEqual(try Data(contentsOf: package.folder.appendingPathComponent("manifest.json")), bytes)
    }
    func testDeviceDisconnectionLeavesVideoRunningAndNeverSendsAnotherConfiguration() async throws {
        let (root, driver, pump, controller) = try setup()
        defer { controller.stop(reason: "testCleanup"); pump.shutdown(); try? FileManager.default.removeItem(at: root) }
        controller.start(); try await wait { controller.encodedFrames >= 2 }
        let before = controller.encodedFrames
        driver.disconnect(PumpSimulatedTransport.deviceA)
        try await wait { controller.encodedFrames > before }
        controller.reconnectPump(PumpSimulatedTransport.deviceA)
        try await wait { controller.encodedFrames > before + 2 }
        XCTAssertEqual(controller.phase, .recording); XCTAssertTrue(driver.writes.isEmpty)
        controller.stop(reason: "userStopped"); try await wait { controller.phase == .finished }
        XCTAssertTrue(controller.latest?.videoAvailable == true)
        try attachPackage(try XCTUnwrap(controller.latest), name: "native-pump-reconnect-package")
    }
    func testControlInFlightPreventsControllerFromStartingCapture() async throws {
        final class Backend: FreeCaptureBackend {
            var onEvent: ((FreeCaptureEvent) -> Void)?
            var starts = 0
            func start(id: UUID, options: FreeCaptureOptions) throws { starts += 1 }
            func stop(id: UUID, reason: String) {}
            func refresh() {}
            func remove(id: UUID) {}
        }
        let backend = Backend(), controller = FreeCaptureController(backend: backend)
        backend.onEvent?(.pumpControlBusy(true)); controller.start()
        XCTAssertEqual(backend.starts, 0); XCTAssertEqual(controller.phase, .idle)
        backend.onEvent?(.pumpControlBusy(false)); controller.start(); XCTAssertEqual(backend.starts, 1)
        let (root, driver, pump, liveController) = try setup()
        defer { liveController.stop(reason: "testCleanup"); pump.shutdown(); try? FileManager.default.removeItem(at: root) }
        driver.results[PumpSimulatedTransport.deviceA] = .unknown
        driver.holdPending.insert(PumpSimulatedTransport.deviceA)
        let session = try XCTUnwrap(pump.session)
        _ = try await session.applyConfiguration(session.makeRequest(.init()))
        XCTAssertTrue(pump.isBusy); XCTAssertTrue(liveController.pumpControlBusy)
        liveController.start(); XCTAssertEqual(liveController.phase, .idle)
        liveController.reconnectPump(PumpSimulatedTransport.deviceA)
        XCTAssertFalse(pump.isBusy); XCTAssertEqual(driver.writes.count, 1)
        liveController.start(); try await wait { liveController.encodedFrames >= 2 }
        liveController.stop(reason: "userStopped"); try await wait { liveController.phase == .finished }
    }
}
