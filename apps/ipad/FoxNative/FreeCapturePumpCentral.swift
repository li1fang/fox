import CoreBluetooth
import Foundation
import FoxTrainingCore

struct FreeCapturePumpDevice: Identifiable, Equatable {
    var id: UUID
    var name: String
    var alias: String?
    var state = "未连接"
    var canReconnect = false
}
struct FreeCapturePumpSelection {
    private(set) var aliases: [UUID: String] = [:]
    mutating func toggle(_ id: UUID, available: Set<UUID>? = nil) -> Bool {
        if let available, !available.contains(id) { return false }
        if aliases.removeValue(forKey: id) != nil { return true }
        guard let alias = ["pump-A", "pump-B"].first(where: { !aliases.values.contains($0) }) else { return false }
        aliases[id] = alias; return true
    }
}

/// Created without touching Bluetooth. All calls and delegates use the main queue;
/// scanning starts only after the user's explicit selection action.
final class FreeCapturePumpCentral: NSObject, CBCentralManagerDelegate {
    var onDevices: (([FreeCapturePumpDevice], String) -> Void)?
    var onStatus: ((String) -> Void)?
    private var central: CBCentralManager?
    private var found: [UUID: CBPeripheral] = [:]
    private var selection = FreeCapturePumpSelection()
    private var adapters: [UUID: PumpReadOnlyAdapter] = [:]
    private var ownedConnections = Set<UUID>()
    private var closingConnections = Set<UUID>()
    private var scanRequested = false
    private var captureID: String?
    private var clockID: String?
    private var notification: ((PumpNotificationEvent) -> Void)?
    private var connection: ((PumpConnectionEvent) -> Void)?
    private var discoveryStatus = "尚未扫描"
    private var deviceStates: [UUID: String] = [:]
    var selectedAliases: [String] { selection.aliases.values.sorted() }
    var activeAdapterCount: Int { adapters.count }

    func scan() {
        guard captureID == nil else { return }
        scanRequested = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        updateState()
    }
    func stopScan() { scanRequested = false; central?.stopScan(); discoveryStatus = "扫描已停止"; publishDevices() }
    func select(_ id: UUID) {
        guard captureID == nil else { return }
        if !selection.toggle(id, available: Set(found.keys)) { discoveryStatus = "最多选择两台 PUMP" }
        publishDevices()
    }
    private func publishDevices() {
        let devices = found.values.map { FreeCapturePumpDevice(id: $0.identifier, name: String(($0.name ?? "PUMP").prefix(128)), alias: selection.aliases[$0.identifier], state: deviceStates[$0.identifier] ?? "未连接",
            canReconnect: captureID != nil && adapters[$0.identifier] == nil && !closingConnections.contains($0.identifier) && $0.state != .connecting) }
            .sorted { ($0.alias ?? "z", $0.name, $0.id.uuidString) < ($1.alias ?? "z", $1.name, $1.id.uuidString) }
        onDevices?(devices, discoveryStatus)
    }
    private func status(alias: String, label: String) {
        if let id = selection.aliases.first(where: { $0.value == alias })?.key {
            guard deviceStates[id] != label else { return }
            deviceStates[id] = label; publishDevices()
        }
        onStatus?("\(alias) \(label)")
    }
    func begin(captureID: String, clockID: String, notification: @escaping (PumpNotificationEvent) -> Void,
               connection: @escaping (PumpConnectionEvent) -> Void) {
        guard self.captureID == nil else { return }
        stopScan(); self.captureID = captureID; self.clockID = clockID
        self.notification = notification; self.connection = connection
        publishDevices()
        guard !selection.aliases.isEmpty else { onStatus?("未选择 PUMP · 录像继续"); return }
        guard central?.state == .poweredOn else {
            for alias in selectedAliases { failure(alias: alias, reason: "bluetooth_unavailable"); status(alias: alias, label: stateLabel) }
            onStatus?(stateLabel); return
        }
        for (id, alias) in selection.aliases {
            guard let peripheral = found[id] else { failure(alias: alias, reason: "selected_device_unavailable"); continue }
            guard !closingConnections.contains(id) else { failure(alias: alias, reason: "previous_disconnect_pending"); status(alias: alias, label: "上次断开尚未完成 · 录像继续"); continue }
            if peripheral.state == .connected { adopt(peripheral) }
            else { ownedConnections.insert(id); central?.connect(peripheral); status(alias: alias, label: "正在连接 · 尚无数据") }
        }
    }
    func stop() {
        stopScan()
        for adapter in adapters.values { adapter.stop() }
        adapters = [:]
        for id in ownedConnections { if let p = found[id] { closingConnections.insert(id); central?.cancelPeripheralConnection(p) } }
        ownedConnections = []; captureID = nil; clockID = nil; notification = nil; connection = nil
        publishDevices()
    }
    func reconnect(_ id: UUID) {
        guard captureID != nil, let alias = selection.aliases[id], let peripheral = found[id], adapters[id] == nil,
              !closingConnections.contains(id), peripheral.state != .connecting else { return }
        guard central?.state == .poweredOn else { failure(alias: alias, reason: "bluetooth_unavailable"); status(alias: alias, label: stateLabel); return }
        if peripheral.state == .connected { adopt(peripheral) }
        else { ownedConnections.insert(id); central?.connect(peripheral); status(alias: alias, label: "正在连接 · 尚无数据") }
    }
    private func adopt(_ peripheral: CBPeripheral) {
        guard let captureID, let clockID, let alias = selection.aliases[peripheral.identifier] else { return }
        let adapter = PumpReadOnlyAdapter(captureID: captureID, deviceAlias: alias, hostClockID: clockID)
        bindAdapter(adapter, deviceID: peripheral.identifier, alias: alias)
        if adapter.begin(peripheral) { publishDevices() }
        else { status(alias: alias, label: "未接手遥测 · 录像继续") }
    }
    // Connection-independent delegate wiring also permits synthetic lifecycle tests.
    func bindAdapter(_ adapter: PumpReadOnlyAdapter, deviceID: UUID, alias: String) {
        adapters[deviceID] = adapter
        adapter.onNotification = { [weak self, weak adapter] event in
            guard let self, let adapter, self.captureID == event.captureID, self.adapters[deviceID] === adapter else { return }
            self.notification?(event); self.status(alias: event.deviceAlias, label: "正在接收通知 · 单位待核对")
        }
        adapter.onState = { [weak self, weak adapter] event in
            guard let self, let adapter, self.captureID == event.captureID, self.adapters[deviceID] === adapter else { return }
            self.connection?(event)
            if event.state == "failed" {
                // Only this lease's adapter is stopped. Its stop emits the matching
                // disconnected event before removal; older leases cannot remove a retry.
                adapter.stop()
                if self.adapters[deviceID] === adapter { self.adapters.removeValue(forKey: deviceID) }
                self.publishDevices()
            }
            let label: String
            switch event.state {
            case "discovering": label = "正在发现遥测特征"
            case "subscribed_no_data": label = "已订阅 · 尚无数据"
            case "receiving": label = "正在接收通知 · 单位待核对"
            case "disconnected": label = "已断开 · 录像继续"
            default: label = "遥测不可用 · 录像继续"
            }
            self.status(alias: event.deviceAlias, label: label)
        }
    }
    private func failure(alias: String, reason: String) {
        guard let captureID, let clockID else { return }
        connection?(.init(captureID: captureID, deviceAlias: alias, connectionSegmentID: UUID().uuidString, hostClockID: clockID,
                          hostReceivedNS: DispatchTime.now().uptimeNanoseconds, state: "failed", reason: reason))
    }
    private var stateLabel: String {
        switch central?.state {
        case .poweredOn: return "蓝牙可用"
        case .poweredOff: return "蓝牙未开启 · 录像可继续"
        case .unauthorized: return "蓝牙权限未开启 · 录像可继续"
        case .unsupported: return "设备不支持蓝牙 · 录像可继续"
        default: return "等待蓝牙状态"
        }
    }
    private func updateState() {
        discoveryStatus = stateLabel
        if central?.state == .poweredOn, scanRequested {
            central?.scanForPeripherals(withServices: [PumpReadOnlyAdapter.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            discoveryStatus = "扫描中，请选择设备"
        }
        publishDevices()
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateState()
        if captureID != nil, central.state != .poweredOn {
            for adapter in adapters.values { adapter.disconnected(reason: "bluetooth_unavailable") }
            adapters = [:]; onStatus?(stateLabel)
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanRequested else { return }
        found[peripheral.identifier] = peripheral; publishDevices()
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if closingConnections.contains(peripheral.identifier) { central.cancelPeripheralConnection(peripheral); return }
        guard captureID != nil, selection.aliases[peripheral.identifier] != nil else {
            if ownedConnections.remove(peripheral.identifier) != nil { central.cancelPeripheralConnection(peripheral) }
            return
        }
        adopt(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if closingConnections.remove(peripheral.identifier) != nil { publishDevices(); return }
        guard let alias = selection.aliases[peripheral.identifier], captureID != nil else { return }
        failure(alias: alias, reason: "connect_failed"); status(alias: alias, label: "连接失败 · 录像继续")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if closingConnections.remove(peripheral.identifier) != nil { publishDevices(); return }
        guard let alias = selection.aliases[peripheral.identifier], captureID != nil else { return }
        adapters.removeValue(forKey: peripheral.identifier)?.disconnected(reason: "connection_lost")
        ownedConnections.remove(peripheral.identifier)
        publishDevices()
        status(alias: alias, label: "已断开 · 录像继续")
    }
}
