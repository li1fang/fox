import Foundation

public struct PumpConfiguration: Codable, Equatable {
    public var mode: PumpMode
    public var kg: Double
    public var reduction: Int
    public init(mode: PumpMode = .standard, kg: Double = 2, reduction: Int = 0) {
        self.mode = mode; self.kg = kg; self.reduction = reduction
    }
    public func strength() throws -> PumpStrength {
        try PumpStrength(mode: mode, kg: kg, reduction: reduction, profile: .pumpPro)
    }
}

public struct PumpConfigurationRequest: Identifiable, Equatable {
    public let id: String
    public let devices: [String: String]
    public let configuration: PumpConfiguration
    public init(id: String = UUID().uuidString, devices: [String: String], configuration: PumpConfiguration) throws {
        _ = try PumpGroupRequest(id: id, devices: devices, strength: configuration.strength())
        self.id = id; self.devices = devices; self.configuration = configuration
    }
}

public struct PumpDeviceSnapshot: Identifiable, Equatable, Codable {
    public let id: UUID
    public var name: String
    public var alias: String?
    public var state = "disconnected"
    public var writable = false
    public var heartbeatNS: UInt64?
    public var workState: Int?
    public init(id: UUID, name: String, alias: String? = nil) { self.id = id; self.name = name; self.alias = alias }
    public func readiness(at now: UInt64) -> String? {
        guard state == "connected", writable else { return "连接或写入特征尚未就绪" }
        guard let heartbeatNS, now >= heartbeatNS, now - heartbeatNS <= 3_000_000_000 else { return "等待有效设备心跳" }
        guard workState == 1 else { return "设备尚未工作就绪或报告故障（\(workState.map(String.init) ?? "未知")）" }
        return nil
    }
}

public struct PumpControlEvent: Codable, Equatable {
    public var schema = "fox.pump_control_event.v1"
    public var synthetic: Bool
    public var eventID: String
    public var sessionID: String
    public var hostClockID: String
    public var hostReceivedNS: String
    public var utc: String
    public var kind: String
    public var deviceID: String?
    public var deviceAlias: String?
    public var requestID: String?
    public var requestDevices: [String: String]?
    public var captureID: String?
    public var configuration: PumpConfiguration?
    public var packetHex: String?
    public var outcomes: [String: String]?
    public var rawHex: String?
    public var state: String?
    public var connectionSegmentID: String?
    enum CodingKeys: String, CodingKey {
        case schema, synthetic, utc, kind, configuration, outcomes, state
        case eventID = "event_id", sessionID = "session_id", hostClockID = "host_clock_id", hostReceivedNS = "host_received_ns"
        case deviceID = "device_id", deviceAlias = "device_alias", requestID = "request_id", captureID = "capture_id"
        case requestDevices = "request_devices"
        case packetHex = "packet_hex", rawHex = "raw_hex", connectionSegmentID = "connection_segment_id"
    }
}

public struct PumpCaptureContext: Codable, Equatable {
    public var schema = "fox.pump_capture_context.v1"
    public let sessionID: String
    public let captureID: String
    public let hostClockID: String
    public let devices: [PumpDeviceSnapshot]
    public let events: [PumpControlEvent]
    enum CodingKeys: String, CodingKey {
        case schema, devices, events
        case sessionID = "session_id", captureID = "capture_id", hostClockID = "host_clock_id"
    }
    public func validate() throws {
        guard schema == "fox.pump_capture_context.v1", !sessionID.isEmpty, !hostClockID.isEmpty,
              devices.count <= 2, Set(devices.map(\.id)).count == devices.count,
              Set(devices.compactMap(\.alias)).count == devices.count,
              devices.allSatisfy({ ["pump-A", "pump-B"].contains($0.alias ?? "") }) else {
            throw PumpError.rejected("PUMP上下文身份不一致")
        }
        for event in events {
            guard event.schema == "fox.pump_control_event.v1", event.sessionID == sessionID, event.hostClockID == hostClockID,
                  UInt64(event.hostReceivedNS) != nil, event.captureID == nil || event.captureID == captureID else {
                throw PumpError.rejected("PUMP控制事件来源不一致")
            }
            if let configuration = event.configuration {
                guard let pair = event.requestDevices, PumpRememberedPair.validated(pair) != nil, event.requestID != nil else {
                    throw PumpError.rejected("PUMP配置缺少当时的设备映射")
                }
                guard event.packetHex == (try configuration.strength()).packet.pumpHex else { throw PumpError.rejected("PUMP配置与报文不一致") }
            } else if event.packetHex != nil { throw PumpError.rejected("PUMP报文缺少参数") }
        }
    }
}

public struct PumpRawNotification {
    public let deviceID: UUID
    public let alias: String
    public let segmentID: String
    public let sequence: UInt64
    public let hostClockID: String
    public let hostReceivedNS: UInt64
    public let bytes: Data
}

public enum PumpTransportEvent {
    case discovered(UUID, String)
    case connection(UUID, String)
    case ready(UUID, Bool)
    case writePending(UUID, String, Bool)
    case notification(UUID, Data, UInt64)
    case status(String)
}

@MainActor public protocol PumpTransport: AnyObject {
    var onEvent: ((PumpTransportEvent) -> Void)? { get set }
    func scan()
    func stopScan()
    func connect(_ id: UUID)
    func disconnect(_ id: UUID)
    func write(_ bytes: Data, to id: UUID, requestID: String) async -> PumpLegResult
}

@MainActor public protocol PumpTelemetrySource: AnyObject {
    var clockID: String { get }
    var selected: [PumpDeviceSnapshot] { get }
    @discardableResult func subscribe(_ sink: @escaping (PumpRawNotification) -> Void) -> UUID
    func unsubscribe(_ token: UUID)
}

@MainActor public protocol PumpConfigurationControl: AnyObject {
    var isApplying: Bool { get }
    var hasPendingWrites: Bool { get }
    var lastResult: PumpGroupResult? { get }
    func readiness() -> String?
    func makeRequest(_ configuration: PumpConfiguration) throws -> PumpConfigurationRequest
    func applyConfiguration(_ request: PumpConfigurationRequest, reviewedPrevious: Bool) async throws -> PumpGroupResult
}

/// Owns device facts and configuration, never camera, pose or training records.
/// Capture subscriptions can detach without changing a cable setting or connection.
@MainActor public final class PumpDeviceSession: PumpTelemetrySource, PumpConfigurationControl {
    public let id = UUID().uuidString
    public let clockID: String
    public let directory: URL
    public var onChange: (() -> Void)?
    public var onPairChanged: (([String: String]) -> Void)?
    public var onConnection: ((PumpControlEvent) -> Void)?
    public private(set) var devices: [PumpDeviceSnapshot] = []
    public private(set) var isApplying = false
    public private(set) var captureID: UUID?
    public private(set) var lastResult: PumpGroupResult?
    public private(set) var lastConfiguration: PumpConfiguration?
    public private(set) var storageError: String?
    public private(set) var status = "尚未扫描"
    private let transport: PumpTransport
    private let now: () -> UInt64
    private let synthetic: Bool
    private let persist: (Data) throws -> Void
    private let group = PumpGroupController()
    private var subscribers: [UUID: (PumpRawNotification) -> Void] = [:]
    private var controls: [PumpControlEvent] = []
    private var segments: [UUID: String] = [:]
    private var sequences: [UUID: UInt64] = [:]
    private var enabled = true
    private var pendingWrites: [UUID: String] = [:]
    public var hasPendingWrites: Bool { !pendingWrites.isEmpty }
    public func connectionSegmentID(for device: UUID) -> String? { segments[device] }
    public var selected: [PumpDeviceSnapshot] { devices.filter { $0.alias != nil }.sorted { $0.alias! < $1.alias! } }
    public var rememberedPair: [String: String] {
        Dictionary(uniqueKeysWithValues: selected.map { ($0.alias == "pump-A" ? "A" : "B", $0.id.uuidString) })
    }
    public var requiresRecovery: Bool { group.requiresRecovery }
    public var telemetry: PumpTelemetrySource { self }
    public var control: PumpConfigurationControl { self }

    public init(transport: PumpTransport, directory: URL, clockID: String = "host-\(UUID().uuidString)",
                now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }, persist: ((Data) throws -> Void)? = nil, synthetic: Bool = false) throws {
        self.transport = transport; self.directory = directory; self.clockID = clockID; self.now = now; self.synthetic = synthetic
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("events.jsonl")
        guard !FileManager.default.fileExists(atPath: file.path), FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw PumpError.rejected("设备会话日志已存在，未覆盖")
        }
        let handle = try FileHandle(forWritingTo: file)
        self.persist = persist ?? { data in try handle.write(contentsOf: data) }
        transport.onEvent = { [weak self] event in self?.receive(event) }
        try record("session_started")
    }

    public func scan() { guard captureID == nil, !isApplying else { return }; enabled = true; status = "扫描中"; transport.scan(); onChange?() }
    public func stopScan() { transport.stopScan() }
    public func restorePair(_ pair: [String: String]) {
        guard let pair = PumpRememberedPair.validated(pair), captureID == nil, !isApplying else { return }
        for device in selected where !pair.values.contains(device.id.uuidString) { transport.disconnect(device.id) }
        devices = devices.map { var d = $0; d.alias = nil; return d }
        for slot in ["A", "B"] { select(id: UUID(uuidString: pair[slot]!)!, name: "已登记 PUMP \(slot)") }
    }
    public func select(id: UUID, name: String) {
        guard captureID == nil, !isApplying else { return }
        if let index = devices.firstIndex(where: { $0.id == id }), devices[index].alias != nil {
            transport.disconnect(id); devices[index].alias = nil
        } else {
            guard selected.count < 2 else { status = "最多选择两台 PUMP"; onChange?(); return }
            let alias = selected.contains { $0.alias == "pump-A" } ? "pump-B" : "pump-A"
            if let index = devices.firstIndex(where: { $0.id == id }) { devices[index].alias = alias }
            else { devices.append(.init(id: id, name: name, alias: alias)) }
        }
        onPairChanged?(rememberedPair); onChange?()
    }
    public func connectSelected() {
        enabled = true; transport.stopScan()
        for device in selected where device.state != "connected" && device.state != "connecting" { transport.connect(device.id) }
    }
    public func disconnect() {
        enabled = false; transport.stopScan(); group.cancel()
        for device in selected { transport.disconnect(device.id) }
        onChange?()
    }
    public func reconnect(_ id: UUID) {
        guard selected.contains(where: { $0.id == id }), !isApplying else { return }
        enabled = true; transport.disconnect(id); transport.connect(id)
    }
    public func readiness() -> String? {
        guard enabled, storageError == nil else { return storageError ?? "连接已停用" }
        guard selected.count == 2 else { return "请选择两台不同的 PUMP" }
        if isApplying { return "正在设置这一对" }
        if hasPendingWrites { return "上次写入仍待回调；可等待或重新连接，未自动补发" }
        if captureID != nil { return "录像或封存中，只读遥测" }
        for d in selected { if let reason = d.readiness(at: now()) { return "\(d.alias!): \(reason)" } }
        return nil
    }
    public func makeRequest(_ configuration: PumpConfiguration) throws -> PumpConfigurationRequest {
        if let reason = readiness() { throw PumpError.rejected(reason) }
        return try PumpConfigurationRequest(devices: rememberedPair, configuration: configuration)
    }
    public func applyConfiguration(_ request: PumpConfigurationRequest, reviewedPrevious: Bool = false) async throws -> PumpGroupResult {
        if let reason = readiness() { throw PumpError.rejected(reason) }
        guard request.devices == rememberedPair else { throw PumpError.rejected("设备选择已变化，请重新核对") }
        _ = try request.configuration.strength()
        if reviewedPrevious { group.acknowledgeRecovery() }
        isApplying = true; onChange?()
        defer { isApplying = false; onChange?() }
        try record("configuration_requested", request: request)
        let result = try await group.run(try .init(id: request.id, devices: request.devices, strength: request.configuration.strength()),
            pairConfirmed: true, stopConfirmed: true, preflight: { [self] slot, id in
                guard enabled, captureID == nil, storageError == nil,
                      let device = selected.first(where: { $0.id.uuidString == id && $0.alias == "pump-\(slot)" }) else {
                    throw PumpError.rejected("连接、设备或采集状态已变化")
                }
                if let reason = device.readiness(at: now()) { throw PumpError.rejected(reason) }
            }, record: { [self] phase, result in
                try record(phase, request: request, outcomes: result.devices.mapValues(\.rawValue))
            }, send: { [self] slot, strength, id in
                await transport.write(strength.packet, to: UUID(uuidString: request.devices[slot]!)!, requestID: id)
            })
        lastResult = result; lastConfiguration = request.configuration
        return result
    }
    @discardableResult public func subscribe(_ sink: @escaping (PumpRawNotification) -> Void) -> UUID {
        let token = UUID(); subscribers[token] = sink; return token
    }
    public func unsubscribe(_ token: UUID) { subscribers.removeValue(forKey: token) }
    public func beginCapture(_ id: UUID) throws -> PumpCaptureContext {
        guard captureID == nil, !isApplying, !hasPendingWrites else { throw PumpError.rejected("上次写入尚未排空，请等待回调或重新连接") }
        let event = try record("capture_attached", capture: id)
        captureID = id; onChange?()
        return PumpCaptureContext(sessionID: self.id, captureID: id.uuidString, hostClockID: clockID, devices: selected, events: controls + [event])
    }
    public func endCapture(_ id: UUID) {
        guard captureID == id else { return }
        _ = try? record("capture_detached", capture: id)
        captureID = nil; onChange?()
    }
    @discardableResult private func record(_ kind: String, device: UUID? = nil, raw: Data? = nil, request: PumpConfigurationRequest? = nil,
                                        outcomes: [String: String]? = nil, state: String? = nil, capture: UUID? = nil, timestamp: UInt64? = nil) throws -> PumpControlEvent {
        let alias = devices.first(where: { $0.id == device })?.alias
        let event = PumpControlEvent(synthetic: synthetic, eventID: UUID().uuidString, sessionID: id, hostClockID: clockID,
            hostReceivedNS: String(timestamp ?? now()), utc: ISO8601DateFormatter().string(from: Date()), kind: kind,
            deviceID: device?.uuidString, deviceAlias: alias, requestID: request?.id, requestDevices: request?.devices, captureID: capture?.uuidString,
            configuration: request?.configuration, packetHex: try request?.configuration.strength().packet.pumpHex,
            outcomes: outcomes, rawHex: raw?.pumpHex, state: state, connectionSegmentID: device.flatMap { segments[$0] })
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try persist(encoder.encode(event) + Data([10]))
            if request != nil { controls.append(event) }
            return event
        } catch { storageError = error.localizedDescription; onChange?(); throw error }
    }
    private func receive(_ event: PumpTransportEvent) {
        switch event {
        case .status(let message): status = message
        case .discovered(let id, let name):
            if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].name = name }
            else { devices.append(.init(id: id, name: name)) }
        case .connection(let id, let state):
            guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
            let previous = devices[i].state
            if previous == "disconnected", state == "disconnected" { return }
            devices[i].state = state
            if state == "disconnected" { pendingWrites.removeValue(forKey: id) }
            if state == "connecting" || (state == "connected" && previous != "connecting") { segments[id] = UUID().uuidString; sequences[id] = 0 }
            if state != "connected" { devices[i].writable = false; devices[i].heartbeatNS = nil; devices[i].workState = nil }
            if let event = try? record("connection", device: id, state: state) { onConnection?(event) }
        case .ready(let id, let value):
            if let i = devices.firstIndex(where: { $0.id == id }) {
                devices[i].writable = value
                if let event = try? record("connection", device: id, state: devices[i].state) { onConnection?(event) }
            }
        case .writePending(let id, let request, let pending):
            if pending { pendingWrites[id] = request }
            else if pendingWrites[id] == request { pendingWrites.removeValue(forKey: id) }
        case .notification(let id, let bytes, let timestamp):
            guard let i = devices.firstIndex(where: { $0.id == id }), let alias = devices[i].alias, let segment = segments[id] else { return }
            _ = try? record("notification", device: id, raw: bytes, timestamp: timestamp)
            if let frame = try? PumpFrame(bytes), frame.profileValid, frame.tag == 2 {
                devices[i].heartbeatNS = timestamp; devices[i].workState = frame.fields["work_state_raw"] as? Int
            }
            let value = PumpRawNotification(deviceID: id, alias: alias, segmentID: segment, sequence: sequences[id, default: 0],
                hostClockID: clockID, hostReceivedNS: timestamp, bytes: bytes)
            sequences[id, default: 0] += 1
            for sink in Array(subscribers.values) { sink(value) }
            // Sports packets can be high-rate. Only device heartbeat/status affects
            // the configuration UI; raw capture still receives every notification.
            if (try? PumpFrame(bytes).tag) != 2 { return }
        }
        onChange?()
    }
}
