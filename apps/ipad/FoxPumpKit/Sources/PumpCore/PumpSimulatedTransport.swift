#if DEBUG
import Foundation

/// Explicit fake for UI/consumer development; never selected by the BLE transport.
@MainActor public final class PumpSimulatedTransport: PumpTransport {
    public static let deviceA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let deviceB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public var onEvent: ((PumpTransportEvent) -> Void)?
    public var results: [UUID: PumpLegResult] = [:]
    public var holdPending = Set<UUID>()
    public private(set) var writes: [(UUID, Data)] = []
    private var connected = Set<UUID>()
    private var timer: Timer?
    public init() {}
    public func scan() {
        onEvent?(.discovered(Self.deviceA, "模拟 PUMP A")); onEvent?(.discovered(Self.deviceB, "模拟 PUMP B"))
    }
    public func stopScan() {}
    public func connect(_ id: UUID) {
        connected.insert(id); onEvent?(.connection(id, "connected")); onEvent?(.ready(id, true)); heartbeat(id)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; for id in self.connected { self.heartbeat(id) } }
            }
        }
    }
    public func disconnect(_ id: UUID) {
        guard connected.remove(id) != nil else { return }
        onEvent?(.connection(id, "disconnected"))
        if connected.isEmpty { timer?.invalidate(); timer = nil }
    }
    public func write(_ bytes: Data, to id: UUID, requestID: String) async -> PumpLegResult {
        guard connected.contains(id) else { return .notSent }
        onEvent?(.writePending(id, requestID, true)); onEvent?(.ready(id, false))
        writes.append((id, bytes))
        if !holdPending.contains(id) { onEvent?(.writePending(id, requestID, false)); onEvent?(.ready(id, true)) }
        return results[id] ?? .gattAckUnverified
    }
    public func heartbeat(_ id: UUID) {
        var bytes: [UInt8] = [0x53, 11, 2, 1, 42, 42, 42, 80, 1, 0]
        bytes.append(0 &- bytes.reduce(0, &+))
        onEvent?(.notification(id, Data(bytes), DispatchTime.now().uptimeNanoseconds))
    }
}
#endif
