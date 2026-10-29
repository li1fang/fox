import XCTest
import FoxTrainingCore
@testable import Fox

final class FreeCapturePumpTests: XCTestCase {
    func testExplicitSelectionHasTwoStableAliasesWithoutAnatomicalAssumptions() {
        var selection = FreeCapturePumpSelection()
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertTrue(selection.aliases.isEmpty)
        XCTAssertTrue(selection.toggle(a)); XCTAssertTrue(selection.toggle(b))
        XCTAssertEqual(selection.aliases[a], "pump-A"); XCTAssertEqual(selection.aliases[b], "pump-B")
        XCTAssertFalse(selection.toggle(c)); XCTAssertNil(selection.aliases[c])
        XCTAssertTrue(selection.toggle(a)); XCTAssertTrue(selection.toggle(c))
        XCTAssertEqual(selection.aliases[b], "pump-B"); XCTAssertEqual(selection.aliases[c], "pump-A")
    }
    func testUnknownPeripheralCannotBeSelectedOrSilentlyReplaceADevice() {
        var selection = FreeCapturePumpSelection()
        let known = UUID(), unknown = UUID()
        XCTAssertFalse(selection.toggle(unknown, available: [known]))
        XCTAssertTrue(selection.toggle(known, available: [known]))
        XCTAssertFalse(selection.toggle(unknown, available: [known]))
        XCTAssertEqual(selection.aliases.count, 1)
    }
    func testInterleavedDevicesKeepSeparateRawFilesAndDisconnectDoesNotEraseNotifications() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PumpArchive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), archive = try FreeCaptureArchive(id: id, options: .init(analysis: .none, pumpEnabled: true), root: root,
                                                        synthetic: true, pumpAliases: ["pump-A", "pump-B"])
        let raw = Data([0x53, 0x0b, 0x02, 0x01, 0x30, 0x28, 0x32, 0x50, 0x02, 0x09, 0xba])
        for (alias, segment) in [("pump-A", "a1"), ("pump-B", "b1")] {
            try archive.pump(PumpConnectionEvent(captureID: id.uuidString, deviceAlias: alias, connectionSegmentID: segment,
                hostClockID: archive.clockID, hostReceivedNS: DispatchTime.now().uptimeNanoseconds, state: "subscribed_no_data", reason: nil))
            try archive.pump(PumpNotificationEvent(captureID: id.uuidString, deviceAlias: alias, connectionSegmentID: segment,
                hostClockID: archive.clockID, notificationSeq: 0, hostReceivedNS: DispatchTime.now().uptimeNanoseconds, bytes: raw))
        }
        try archive.pump(PumpConnectionEvent(captureID: id.uuidString, deviceAlias: "pump-A", connectionSegmentID: "a1",
            hostClockID: archive.clockID, hostReceivedNS: DispatchTime.now().uptimeNanoseconds, state: "disconnected", reason: "connection_lost"))
        _ = try archive.seal(video: nil, reason: "userStopped")
        let manifest = try JSONDecoder().decode(LabCaptureManifest.self, from: Data(contentsOf: archive.folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.streams.first { $0.id == "pump-A" }?.state, "interrupted")
        XCTAssertEqual(manifest.streams.first { $0.id == "pump-B" }?.state, "complete")
        XCTAssertEqual(Set(manifest.streams.filter { $0.kind == "pump_raw" }.compactMap { $0.source.deviceAlias }), ["pump-A", "pump-B"])
        for alias in ["pump-A", "pump-B"] {
            let rows = try String(contentsOf: archive.folder.appendingPathComponent("\(alias).jsonl"))
            XCTAssertTrue(rows.contains(raw.map { String(format: "%02x", $0) }.joined()))
            XCTAssertFalse(rows.contains(alias == "pump-A" ? "pump-B" : "pump-A"))
            XCTAssertFalse(rows.contains("force_n")); XCTAssertFalse(rows.contains("position_m"))
        }
    }
    func testForeignCaptureOrClockIsRejectedWithoutAddingItToCurrentOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PumpBinding-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), archive = try FreeCaptureArchive(id: id, options: .init(analysis: .none, pumpEnabled: true), root: root,
                                                        synthetic: true, pumpAliases: ["pump-A"])
        let file = archive.folder.appendingPathComponent("pump-A.jsonl"), before = try Data(contentsOf: file)
        let foreign = PumpNotificationEvent(captureID: "other-capture", deviceAlias: "pump-A", connectionSegmentID: "a1",
            hostClockID: archive.clockID, notificationSeq: 0, hostReceivedNS: DispatchTime.now().uptimeNanoseconds, bytes: Data([1]))
        XCTAssertThrowsError(try archive.pump(foreign))
        let wrongClock = PumpNotificationEvent(captureID: id.uuidString, deviceAlias: "pump-A", connectionSegmentID: "a1",
            hostClockID: "other-clock", notificationSeq: 0, hostReceivedNS: DispatchTime.now().uptimeNanoseconds, bytes: Data([1]))
        XCTAssertThrowsError(try archive.pump(wrongClock))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testFailedAdapterReleasesItsSlotAndOldFailureCannotRemoveRetry() {
        let central = FreeCapturePumpCentral(), device = UUID()
        var events: [PumpConnectionEvent] = []
        // No scan/manager/peripheral is created; this exercises the real delegate wiring.
        central.begin(captureID: "synthetic-capture", clockID: "host-1", notification: { _ in }, connection: { events.append($0) })
        let first = PumpReadOnlyAdapter(captureID: "synthetic-capture", deviceAlias: "pump-A", hostClockID: "host-1")
        central.bindAdapter(first, deviceID: device, alias: "pump-A")
        let failed = PumpConnectionEvent(captureID: "synthetic-capture", deviceAlias: "pump-A", connectionSegmentID: "segment-1",
            hostClockID: "host-1", hostReceivedNS: 1, state: "failed", reason: "service_unavailable")
        first.onState?(failed)
        XCTAssertEqual(central.activeAdapterCount, 0); XCTAssertEqual(events.count, 1)
        let retry = PumpReadOnlyAdapter(captureID: "synthetic-capture", deviceAlias: "pump-A", hostClockID: "host-1")
        central.bindAdapter(retry, deviceID: device, alias: "pump-A")
        first.onState?(failed)
        XCTAssertEqual(central.activeAdapterCount, 1); XCTAssertEqual(events.count, 1)
        retry.onState?(PumpConnectionEvent(captureID: "synthetic-capture", deviceAlias: "pump-A", connectionSegmentID: "segment-2",
            hostClockID: "host-1", hostReceivedNS: 2, state: "failed", reason: "subscription_failed"))
        XCTAssertEqual(central.activeAdapterCount, 0); XCTAssertEqual(events.count, 2)
        central.stop()
    }
}
