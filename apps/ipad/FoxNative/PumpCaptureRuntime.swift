import Combine
import Foundation
import FoxPumpApple
import FoxTrainingCore
import PumpCore

/// UI module: drafts belong here; device facts and persistence belong to the session.
@MainActor final class PumpCaptureRuntime: ObservableObject {
    @Published private(set) var session: PumpDeviceSession?
    @Published var error: String?
    @Published var kgText = "2"
    @Published var mode = PumpMode.standard
    @Published var reduction = 0
    @Published var confirmation: PumpConfigurationRequest?
    var onDevices: (([FreeCapturePumpDevice], String) -> Void)?
    var onBusy: ((Bool) -> Void)?
    var onConnection: ((PumpConnectionEvent) -> Void)?
    private var token: UUID?
    private var attachedCaptureID: UUID?
    private let root: URL
    private let defaults: UserDefaults
    private let transport: PumpTransport
    private let synthetic: Bool
    private var enabled = false
    init(root: URL? = nil, defaults: UserDefaults? = nil, transport: PumpTransport? = nil) {
        let testing = ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = root ?? documents.appendingPathComponent(testing ? "FoxPumpSessionFixtures" : "FoxPumpSessions")
        self.defaults = defaults ?? FoxPreferenceDomain.current
        #if DEBUG
        let fake = testing && ProcessInfo.processInfo.environment["FOX_PUMP_FIXTURE"] != nil
        self.transport = transport ?? (fake ? PumpSimulatedTransport() : ApplePumpTransport())
        synthetic = fake || transport is PumpSimulatedTransport
        #else
        self.transport = transport ?? ApplePumpTransport(); synthetic = false
        #endif
    }
    var devices: [FreeCapturePumpDevice] {
        session?.devices.map { .init(id: $0.id, name: $0.name, alias: $0.alias, state: label($0), canReconnect: $0.alias != nil && $0.state != "connecting") } ?? []
    }
    var selectedAliases: [String] { session?.selected.compactMap(\.alias) ?? [] }
    var isApplying: Bool { session?.isApplying == true }
    var isBusy: Bool { isApplying || session?.hasPendingWrites == true }
    var isSynthetic: Bool { synthetic }
    var configuration: PumpConfiguration? {
        guard let kg = Double(kgText.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let value = PumpConfiguration(mode: mode, kg: kg, reduction: reduction)
        return (try? value.strength()) != nil ? value : nil
    }
    var minimum: Double { PumpMachineProfile.pumpPro.minimum(mode) }
    var validationMessage: String? { configuration == nil ? "请输入本模式 \(Int(minimum))–20 kg，最多一位小数；非方向模式减载须为0。" : nil }
    var readiness: String { session?.readiness() ?? error ?? "请选择并连接两台 PUMP" }
    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { shutdown(); return }
        ensureSession()
        guard let session else { return }
        if session.selected.isEmpty, let pair = defaults.dictionary(forKey: "Fox.PumpPair.v1") as? [String: String] { session.restorePair(pair) }
        session.connectSelected(); changed()
    }
    private func ensureSession() {
        guard session == nil else { return }
        do {
            let session = try PumpDeviceSession(transport: transport, directory: root.appendingPathComponent(UUID().uuidString),
                clockID: "host-\(FreeCaptureArchive.processID.uuidString)", synthetic: synthetic)
            session.onChange = { [weak self] in self?.changed() }
            session.onConnection = { [weak self] event in
                guard let self, let session = self.session, let id = self.attachedCaptureID,
                      let timestamp = UInt64(event.hostReceivedNS) else { return }
                guard let device = session.devices.first(where: { $0.id.uuidString == event.deviceID }),
                      let value = self.connectionEvent(device, captureID: id, timestamp: timestamp) else { return }
                self.onConnection?(value)
            }
            session.onPairChanged = { [weak self] pair in
                guard let self else { return }
                if let pair = PumpRememberedPair.validated(pair) { self.defaults.set(pair, forKey: "Fox.PumpPair.v1") }
                else { self.defaults.removeObject(forKey: "Fox.PumpPair.v1") }
            }
            self.session = session
        } catch { self.error = error.localizedDescription }
    }
    private func changed() {
        objectWillChange.send(); onBusy?(isBusy)
        onDevices?(devices, session?.status ?? error ?? "尚未扫描")
    }
    private func label(_ d: PumpDeviceSnapshot) -> String {
        if d.state != "connected" {
            return d.state == "connecting" ? "正在连接" : d.state == "disconnected" ? "已断开" : d.state
        }
        return d.readiness(at: DispatchTime.now().uptimeNanoseconds) == nil ? "已连接 · 可设置" : "已连接 · 等待心跳或特征"
    }
    func scan() { ensureSession(); session?.scan() }
    func stopScan() { session?.stopScan() }
    func select(_ id: UUID) {
        guard let d = session?.devices.first(where: { $0.id == id }) else { return }
        session?.select(id: id, name: d.name)
        if session?.selected.count == 2 { session?.connectSelected() }
    }
    func reconnect(_ id: UUID) { session?.reconnect(id) }
    func prepareConfirmation() {
        guard let session, let configuration else { error = validationMessage ?? readiness; return }
        do { confirmation = try session.makeRequest(configuration); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func applyConfirmed(_ request: PumpConfigurationRequest) async {
        confirmation = nil
        do { _ = try await session?.applyConfiguration(request, reviewedPrevious: session?.requiresRecovery == true); error = nil }
        catch { self.error = error.localizedDescription }
        changed()
    }
    func begin(id: UUID, notification: @escaping (PumpNotificationEvent) -> Void, connection: @escaping (PumpConnectionEvent) -> Void) -> PumpCaptureContext? {
        ensureSession(); guard let session else { return nil }
        do {
            let context = try session.beginCapture(id); attachedCaptureID = id
            token = session.subscribe { value in
                notification(.init(captureID: id.uuidString, deviceAlias: value.alias, connectionSegmentID: value.segmentID,
                    hostClockID: value.hostClockID, notificationSeq: value.sequence, hostReceivedNS: value.hostReceivedNS, bytes: value.bytes))
            }
            onConnection = connection
            return context
        } catch { self.error = error.localizedDescription; return nil }
    }
    func connectionEvent(_ device: PumpDeviceSnapshot, captureID: UUID, timestamp: UInt64) -> PumpConnectionEvent? {
        guard let session, let alias = device.alias, device.state != "disconnecting" else { return nil }
        let state: String
        let reason: String?
        switch device.state {
        case "connected": state = device.writable ? "subscribed_no_data" : "discovering"; reason = nil
        case "connecting": state = "discovering"; reason = nil
        case "disconnected": state = "disconnected"; reason = "connection_ended"
        default: state = "failed"; reason = device.state
        }
        return .init(captureID: captureID.uuidString, deviceAlias: alias,
            connectionSegmentID: session.connectionSegmentID(for: device.id) ?? "pending-\(device.id.uuidString)",
            hostClockID: session.clockID, hostReceivedNS: timestamp, state: state, reason: reason)
    }
    func detachNotifications() { if let token { session?.unsubscribe(token); self.token = nil }; onConnection = nil }
    func finishCapture() {
        detachNotifications()
        if let attachedCaptureID { session?.endCapture(attachedCaptureID) }
        attachedCaptureID = nil
    }
    func shutdown() {
        confirmation = nil; session?.disconnect(); changed()
    }
}
