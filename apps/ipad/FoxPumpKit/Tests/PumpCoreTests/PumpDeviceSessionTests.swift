import XCTest
@testable import PumpCore

@MainActor
final class PumpDeviceSessionTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private var time: UInt64 = 1_000_000_000
    private func fixture(persist: ((Data) throws -> Void)? = nil) throws -> (PumpDeviceSession, TestTransport, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transport = TestTransport(now: { self.time })
        let session = try PumpDeviceSession(transport: transport, directory: root, now: { self.time }, persist: persist)
        transport.onConnected = { id in transport.heartbeat(id) }
        session.select(id: a, name: "test-a"); session.select(id: b, name: "test-b")
        session.connectSelected()
        return (session, transport, root)
    }
    func testStationaryDevicesCanReceiveBothConfigurationsWithoutSportsNotifications() async throws {
        let (session, driver, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try session.makeRequest(.init(mode: .standard, kg: 2))
        let result = try await session.applyConfiguration(request)
        XCTAssertEqual(result.status, .bothAcknowledgedUnverified)
        XCTAssertEqual(driver.writes.count, 2)
        XCTAssertEqual(driver.writes[0].1, driver.writes[1].1)
        XCTAssertEqual(driver.sportsNotifications, 0)
    }
    func testRecordingAndFinalizationPreventWritesButStoppingDoesNotChangeResistance() async throws {
        let (session, driver, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try session.makeRequest(.init(mode: .standard, kg: 2))
        let capture = UUID(); _ = try session.beginCapture(capture)
        do { _ = try await session.applyConfiguration(request); XCTFail("recording wrote") } catch {}
        XCTAssertTrue(driver.writes.isEmpty)
        session.endCapture(capture)
        XCTAssertTrue(driver.writes.isEmpty)
        _ = try await session.applyConfiguration(request)
        XCTAssertEqual(driver.writes.count, 2)
    }
    func testStaleHeartbeatOrDeviceFaultRejectsBeforeAnyWrite() async throws {
        let (session, driver, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try session.makeRequest(.init(mode: .standard, kg: 2))
        time += 4_000_000_000
        do { _ = try await session.applyConfiguration(request); XCTFail("stale") } catch {}
        XCTAssertTrue(driver.writes.isEmpty)
        driver.heartbeat(a, state: 3); driver.heartbeat(b)
        XCTAssertThrowsError(try session.makeRequest(.init(mode: .standard, kg: 2)))
    }
    func testFirstUnknownStopsSecondAndNeverRetriesOnReconnect() async throws {
        let (session, driver, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        driver.nextResult = .unknown
        let result = try await session.applyConfiguration(session.makeRequest(.init(mode: .standard, kg: 2)))
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.devices["B"], .notSent)
        session.disconnect(); session.connectSelected()
        XCTAssertEqual(driver.writes.count, 1)
    }
    func testSecondFailurePreservesFirstAcknowledgementAndDuplicateIDCannotWriteAgain() async throws {
        let (session, driver, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        driver.results[b] = .notSent
        let request = try session.makeRequest(.init(mode: .standard, kg: 2))
        let result = try await session.applyConfiguration(request)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.devices["A"], .gattAckUnverified)
        do { _ = try await session.applyConfiguration(request, reviewedPrevious: true); XCTFail("duplicate") } catch {}
        XCTAssertEqual(driver.writes.count, 2)
    }
    func testConfigurationBeforeCaptureIsPreservedWithOriginalTimeAndDeviceMapping() async throws {
        let (session, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try session.makeRequest(.init(mode: .eccentric, kg: 5, reduction: 25))
        _ = try await session.applyConfiguration(request)
        time += 1_000_000_000
        let context = try session.beginCapture(UUID())
        XCTAssertEqual(context.devices.count, 2)
        XCTAssertTrue(context.events.contains { $0.requestID == request.id && $0.kind == "configuration_requested" && $0.hostReceivedNS == "1000000000" })
        let bytes = try JSONEncoder().encode(context)
        XCTAssertEqual(try JSONDecoder().decode(PumpCaptureContext.self, from: bytes), context)
        XCTAssertNoThrow(try context.validate())
        var events = context.events
        events[0].hostClockID = "other"
        XCTAssertThrowsError(try PumpCaptureContext(sessionID: context.sessionID, captureID: context.captureID,
            hostClockID: context.hostClockID, devices: context.devices, events: events).validate())
        events = context.events; events[0].requestDevices = nil
        XCTAssertThrowsError(try PumpCaptureContext(sessionID: context.sessionID, captureID: context.captureID,
            hostClockID: context.hostClockID, devices: context.devices, events: events).validate())
    }
    func testDisconnectionDoesNotEraseNotificationsOrStopAnotherSubscriber() throws {
        let (session, driver, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var first = 0, second = 0
        let token = session.subscribe { _ in first += 1 }
        _ = session.subscribe { _ in second += 1 }
        driver.heartbeat(a); session.unsubscribe(token); driver.heartbeat(b)
        XCTAssertEqual(first, 1); XCTAssertEqual(second, 2)
        XCTAssertEqual(driver.disconnects, 0)
        var closes = 0
        session.onConnection = { if $0.state == "disconnected" { closes += 1 } }
        driver.disconnect(a); driver.disconnect(a)
        XCTAssertEqual(closes, 1, "A segment can close only once")
    }
    func testJournalFailureRejectsConfigurationWithoutSending() async throws {
        var fail = false
        let (session, driver, root) = try fixture(persist: { _ in if fail { throw CocoaError(.fileWriteOutOfSpace) } })
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try session.makeRequest(.init(mode: .standard, kg: 2))
        fail = true
        do { _ = try await session.applyConfiguration(request); XCTFail("journal") } catch {}
        XCTAssertTrue(driver.writes.isEmpty)
    }
    func testTimedOutUndrainedWriteBlocksCaptureUntilCallbackOrConfirmedDisconnect() async throws {
        let (session, driver, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        driver.nextResult = .unknown; driver.holdPendingAfterResult = true
        _ = try await session.applyConfiguration(session.makeRequest(.init(mode: .standard, kg: 2)))
        let capture = UUID()
        XCTAssertThrowsError(try session.beginCapture(capture))
        session.endCapture(capture)
        driver.onEvent?(.writePending(a, "unrelated-old-request", false))
        XCTAssertThrowsError(try session.beginCapture(capture))
        driver.onEvent?(.connection(a, "disconnecting"))
        XCTAssertThrowsError(try session.beginCapture(capture))
        driver.onEvent?(.connection(a, "connected")); driver.heartbeat(a)
        driver.drain(a)
        XCTAssertNoThrow(try session.beginCapture(capture)); session.endCapture(capture)
        driver.holdPendingAfterResult = true
        _ = try await session.applyConfiguration(session.makeRequest(.init(mode: .standard, kg: 2)), reviewedPrevious: true)
        XCTAssertThrowsError(try session.beginCapture(capture)); session.endCapture(capture)
        session.disconnect()
        XCTAssertNoThrow(try session.beginCapture(capture)); session.endCapture(capture)
    }
    func testHistoricalConfigurationKeepsFrozenDeviceMappingAfterReplacingAPeer() async throws {
        let (session, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try session.makeRequest(.init(mode: .standard, kg: 2))
        _ = try await session.applyConfiguration(request)
        session.select(id: a, name: "test-a")
        session.select(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "test-c")
        session.connectSelected()
        let context = try session.beginCapture(UUID())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        let rows = try XCTUnwrap(json["events"] as? [[String: Any]])
        let event = try XCTUnwrap(rows.first { $0["kind"] as? String == "configuration_requested" })
        XCTAssertEqual(event["request_devices"] as? [String: String], request.devices)
        XCTAssertFalse(context.devices.contains { $0.id == a })
        XCTAssertTrue(context.events.filter { $0.requestID == request.id }.allSatisfy { $0.requestDevices == request.devices })
    }
}

@MainActor
private final class TestTransport: PumpTransport {
    var onEvent: ((PumpTransportEvent) -> Void)?
    var onConnected: ((UUID) -> Void)?
    var nextResult = PumpLegResult.gattAckUnverified
    var results: [UUID: PumpLegResult] = [:]
    var writes: [(UUID, Data)] = []
    var disconnects = 0
    var holdPendingAfterResult = false
    var pending: [UUID: String] = [:]
    let sportsNotifications = 0
    let now: () -> UInt64
    init(now: @escaping () -> UInt64) { self.now = now }
    func scan() {}
    func stopScan() {}
    func connect(_ id: UUID) { onEvent?(.connection(id, "connected")); onEvent?(.ready(id, true)); onConnected?(id) }
    func disconnect(_ id: UUID) { disconnects += 1; onEvent?(.connection(id, "disconnected")) }
    func write(_ bytes: Data, to id: UUID, requestID: String) async -> PumpLegResult {
        if holdPendingAfterResult { pending[id] = requestID; onEvent?(.writePending(id, requestID, true)); onEvent?(.ready(id, false)) }
        writes.append((id, bytes)); return results[id] ?? nextResult
    }
    func drain(_ id: UUID) {
        if let request = pending.removeValue(forKey: id) { onEvent?(.writePending(id, request, false)) }
        onEvent?(.ready(id, true))
    }
    func heartbeat(_ id: UUID, state: UInt8 = 1) {
        var bytes: [UInt8] = [0x53, 11, 2, state, 42, 42, 42, 80, 1, 0]
        bytes.append(0 &- bytes.reduce(0, &+))
        onEvent?(.notification(id, Data(bytes), now()))
    }
}
