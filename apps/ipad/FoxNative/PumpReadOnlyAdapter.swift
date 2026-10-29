import CoreBluetooth
import Foundation
import FoxTrainingCore

/// One adapter per explicitly selected peripheral. Owner supplies connection/permission UI.
/// Call only on the peripheral delegate queue; this object never scans, connects, or writes commands.
final class PumpReadOnlyAdapter: NSObject, CBPeripheralDelegate {
    static let service = CBUUID(string: "0000ffe0-0000-1000-8000-00805f9b34fb")
    static let notification = CBUUID(string: "0000ffe1-0000-1000-8000-00805f9b34fb")
    private let captureID: String
    private let deviceAlias: String
    private let hostClockID: String
    private var peripheral: CBPeripheral?
    private var segmentID: String?
    private var sequence: UInt64 = 0
    private var subscription = PumpNotificationSubscription()
    private var characteristic: CBCharacteristic?
    private var previousDelegate: CBPeripheralDelegate?
    var onNotification: ((PumpNotificationEvent) -> Void)?
    var onState: ((PumpConnectionEvent) -> Void)?
    private let now: () -> UInt64

    init(captureID: String, deviceAlias: String, hostClockID: String, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.captureID = captureID; self.deviceAlias = deviceAlias; self.hostClockID = hostClockID; self.now = now
    }

    /// Only an already-connected peripheral selected by its owner may be adopted.
    func begin(_ selected: CBPeripheral) -> Bool {
        guard peripheral == nil, selected.state == .connected else { return false }
        // Refuse cached preexisting telemetry before taking over its delegate.
        let alreadyNotifying = selected.services?.contains(where: { service in
            service.uuid == Self.service && (service.characteristics?.contains(where: {
                $0.uuid == Self.notification && $0.isNotifying
            }) ?? false)
        }) == true
        if let reason = PumpNotificationSubscription.adoptionRejection(
            hasExistingDelegate: selected.delegate != nil, alreadyNotifying: alreadyNotifying) {
            // Rejection is observable without changing the selected peripheral or its delegate.
            onState?(PumpConnectionEvent(captureID: captureID, deviceAlias: deviceAlias, connectionSegmentID: UUID().uuidString,
                hostClockID: hostClockID, hostReceivedNS: now(), state: "failed", reason: reason))
            return false
        }
        peripheral = selected; segmentID = UUID().uuidString; sequence = 0
        previousDelegate = selected.delegate; selected.delegate = self
        emit("discovering", nil)
        selected.discoverServices([Self.service])
        return true
    }
    /// Owner must call when central reports disconnect; no values are carried across it.
    func disconnected(reason: String) { finish(reason: reason, unsubscribe: false) }
    func stop() { finish(reason: "user_stopped", unsubscribe: true) }
    private func finish(reason: String, unsubscribe: Bool) {
        guard let p = peripheral else { return }
        emit("disconnected", reason)
        let mayUnsubscribe = subscription.release()
        if unsubscribe, mayUnsubscribe, p.state == .connected, let characteristic { p.setNotifyValue(false, for: characteristic) }
        if p.delegate === self { p.delegate = previousDelegate }
        previousDelegate = nil; characteristic = nil; segmentID = nil; peripheral = nil
    }
    private func emit(_ state: String, _ reason: String?) {
        guard let segmentID else { return }
        onState?(PumpConnectionEvent(captureID: captureID, deviceAlias: deviceAlias, connectionSegmentID: segmentID,
                                    hostClockID: hostClockID, hostReceivedNS: now(), state: state, reason: reason))
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        guard error == nil, let services = p.services?.filter({ $0.uuid == Self.service }), services.count == 1 else {
            emit("failed", "service_unavailable"); return
        }
        p.discoverCharacteristics([Self.notification], for: services[0])
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral, service.uuid == Self.service else { return }
        guard error == nil, let values = service.characteristics?.filter({ $0.uuid == Self.notification }), values.count == 1,
              values[0].properties.contains(.notify) else { emit("failed", "notification_unavailable"); return }
        if subscription.ownsSubscription { return }
        guard subscription.requestNewSubscription(alreadyNotifying: values[0].isNotifying) else {
            emit("failed", "existing_subscription")
            finish(reason: "existing_subscription", unsubscribe: false)
            return
        }
        characteristic = values[0]
        // System notification subscription (CCCD); no FFE2 application write or identity query.
        p.setNotifyValue(true, for: values[0])
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor value: CBCharacteristic, error: Error?) {
        guard p === peripheral, value === characteristic else { return }
        emit(error == nil && value.isNotifying ? "subscribed_no_data" : "failed", error == nil && value.isNotifying ? nil : "subscription_failed")
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor value: CBCharacteristic, error: Error?) {
        guard p === peripheral, value === characteristic, let segmentID else { return }
        guard error == nil, let bytes = value.value else { emit("failed", "notification_error"); return }
        onNotification?(PumpNotificationEvent(captureID: captureID, deviceAlias: deviceAlias, connectionSegmentID: segmentID,
                                             hostClockID: hostClockID, notificationSeq: sequence, hostReceivedNS: now(), bytes: bytes))
        sequence += 1
        emit("receiving", nil)
    }
}
