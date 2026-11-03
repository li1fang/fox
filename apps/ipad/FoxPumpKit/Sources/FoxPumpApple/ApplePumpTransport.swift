import CoreBluetooth
import Foundation
import PumpCore

/// The sole BLE/delegate owner. Capture consumers receive values, never peripherals.
@MainActor public final class ApplePumpTransport: NSObject, PumpTransport, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    public var onEvent: ((PumpTransportEvent) -> Void)?
    private final class Link {
        let peripheral: CBPeripheral
        var writer: CBCharacteristic?
        var notify: CBCharacteristic?
        var ledger = PumpWriteLedger()
        var reply: CheckedContinuation<PumpLegResult, Never>?
        var requestID: String?
        var timeout: Task<Void, Never>?
        init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
    }
    private let service = CBUUID(string: "FFE0"), notify = CBUUID(string: "FFE1"), writer = CBUUID(string: "FFE2")
    private var central: CBCentralManager?
    private var found: [UUID: CBPeripheral] = [:]
    private var links: [UUID: Link] = [:]
    private var requested = Set<UUID>()
    private var reconnectAfterDisconnect = Set<UUID>()
    private var owned = Set<UUID>()
    private var scanning = false

    public override init() { super.init() }
    private func initialize() { if central == nil { central = CBCentralManager(delegate: self, queue: .main) } }
    public func scan() { scanning = true; initialize(); update() }
    public func stopScan() { scanning = false; central?.stopScan() }
    public func connect(_ id: UUID) {
        requested.insert(id); initialize()
        guard central?.state == .poweredOn else { return }
        connectNow(id)
    }
    private func connectNow(_ id: UUID) {
        guard requested.contains(id), let central, central.state == .poweredOn else { return }
        guard let p = found[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            onEvent?(.connection(id, "unavailable")); onEvent?(.status("已登记设备尚未找到，请扫描")); return
        }
        found[id] = p
        if p.state == .disconnecting { reconnectAfterDisconnect.insert(id); return }
        if let delegate = p.delegate, delegate !== self {
            onEvent?(.connection(id, "owned_elsewhere")); onEvent?(.status("设备已有其他连接所有者，未接管")); return
        }
        if p.state == .connecting { return }
        owned.insert(id)
        if p.state == .connected { adopt(p) }
        else { onEvent?(.connection(id, "connecting")); central.connect(p) }
    }
    public func disconnect(_ id: UUID) {
        requested.remove(id)
        reconnectAfterDisconnect.remove(id)
        guard owned.contains(id), let p = found[id] else { return }
        onEvent?(.ready(id, false)); onEvent?(.connection(id, "disconnecting"))
        if p.state == .disconnected { close(id) }
        else { central?.cancelPeripheralConnection(p) }
    }
    private func adopt(_ p: CBPeripheral) {
        guard requested.contains(p.identifier), owned.contains(p.identifier) else { central?.cancelPeripheralConnection(p); return }
        guard p.delegate == nil || p.delegate === self else { onEvent?(.connection(p.identifier, "owned_elsewhere")); return }
        if links[p.identifier] != nil { publishReady(p.identifier); return }
        links[p.identifier] = Link(p); p.delegate = self
        onEvent?(.connection(p.identifier, "connected")); p.discoverServices([service])
    }
    private func publishReady(_ id: UUID) {
        let link = links[id]
        onEvent?(.ready(id, link?.peripheral.state == .connected && link?.writer != nil && link?.notify?.isNotifying == true && link?.ledger.pendingRequestID == nil))
    }
    private func close(_ id: UUID) {
        if let link = links.removeValue(forKey: id) {
            link.timeout?.cancel(); link.reply?.resume(returning: .unknown); link.reply = nil
            link.ledger.resetConnection()
            if link.peripheral.delegate === self { link.peripheral.delegate = nil }
        }
        owned.remove(id); onEvent?(.connection(id, "disconnected"))
    }
    public func write(_ bytes: Data, to id: UUID, requestID: String) async -> PumpLegResult {
        guard requested.contains(id), owned.contains(id), let link = links[id], link.peripheral.state == .connected,
              let writer = link.writer, link.notify?.isNotifying == true, link.reply == nil else { return .notSent }
        do { try link.ledger.begin(requestID) } catch { return .notSent }
        link.requestID = requestID; onEvent?(.writePending(id, requestID, true)); onEvent?(.ready(id, false))
        return await withCheckedContinuation { reply in
            link.reply = reply
            link.peripheral.writeValue(bytes, for: writer, type: .withResponse)
            link.timeout = Task { [weak self, weak link] in
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                guard let self, let link, self.links[id] === link, link.requestID == requestID else { return }
                // Timeout completes the caller, not the BLE write ledger. Late ACKs
                // cannot be mistaken for a later request on the same connection.
                self.finish(link, result: .unknown)
            }
        }
    }
    private func finish(_ link: Link, result: PumpLegResult) {
        link.timeout?.cancel(); link.timeout = nil
        let reply = link.reply; link.reply = nil; link.requestID = nil
        reply?.resume(returning: result); publishReady(link.peripheral.identifier)
    }
    private func update() {
        guard let central else { return }
        if central.state == .poweredOn {
            onEvent?(.status(scanning ? "扫描中，请选择设备" : "蓝牙可用"))
            if scanning { central.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]) }
            for id in requested { connectNow(id) }
        } else {
            let message = central.state == .unauthorized ? "蓝牙权限未开启" : central.state == .poweredOff ? "蓝牙未开启" : "等待蓝牙状态"
            onEvent?(.status(message))
            if central.state == .poweredOff || central.state == .unauthorized {
                requested.removeAll(); for id in Array(owned) { close(id) }
            }
        }
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) { update() }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }; found[peripheral.identifier] = peripheral
        onEvent?(.discovered(peripheral.identifier, peripheral.name ?? "PUMP"))
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { adopt(peripheral) }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        close(peripheral.identifier); onEvent?(.status("连接失败，请重试连接"))
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let reconnect = reconnectAfterDisconnect.remove(peripheral.identifier) != nil && requested.contains(peripheral.identifier)
        close(peripheral.identifier)
        // Only an explicit connect received while disconnecting requests this path.
        // Unsolicited loss does not silently reconnect or resend any configuration.
        if reconnect { connectNow(peripheral.identifier) }
        else { requested.remove(peripheral.identifier) }
    }
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard links[p.identifier]?.peripheral === p, error == nil, let s = p.services?.first(where: { $0.uuid == service }) else {
            onEvent?(.status("PUMP 服务不可用")); return
        }
        p.discoverCharacteristics([notify, writer], for: s)
    }
    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let link = links[p.identifier], link.peripheral === p, error == nil, let chars = service.characteristics else { return }
        link.writer = chars.first { $0.uuid == writer && $0.properties.contains(.write) }
        link.notify = chars.first { $0.uuid == notify && $0.properties.contains(.notify) }
        if let notify = link.notify { p.setNotifyValue(true, for: notify) }
        else { onEvent?(.status("PUMP 通知特征不可用")) }
        publishReady(p.identifier)
    }
    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = links[p.identifier], characteristic === link.notify else { return }
        if error != nil { onEvent?(.status("遥测订阅失败，录像可继续")) }
        publishReady(p.identifier)
    }
    public func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = links[p.identifier], characteristic === link.notify, error == nil, let bytes = characteristic.value else { return }
        onEvent?(.notification(p.identifier, bytes, DispatchTime.now().uptimeNanoseconds))
    }
    public func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = links[p.identifier], characteristic === link.writer, let id = link.ledger.acknowledge() else { return }
        onEvent?(.writePending(p.identifier, id, false))
        if link.requestID == id { finish(link, result: error == nil ? .gattAckUnverified : .unknown) }
        else { publishReady(p.identifier) }
    }
}
