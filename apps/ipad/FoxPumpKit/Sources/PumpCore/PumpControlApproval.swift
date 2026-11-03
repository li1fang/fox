import Foundation

/// Native-only, one-shot approval of one exact device/packet. Never persisted.
/// Transport acknowledgement and physical effect are deliberately not inferred.
public struct PumpControlApproval {
    private struct Permit {
        let slot: String
        let device: UUID
        let packet: Data
        let started: TimeInterval
    }
    private var permit: Permit?
    public init() {}
    public mutating func revoke() { permit = nil }
    public mutating func revoke(slot: String) { if permit?.slot == slot { revoke() } }
    public mutating func approve(slot: String, peripheralID: String, strength: PumpStrength,
                                 identityConfirmed: Bool, stopMethodConfirmed: Bool, now: TimeInterval) throws {
        revoke()
        guard ["A","B"].contains(slot), let device = UUID(uuidString:peripheralID),
              identityConfirmed, stopMethodConfirmed, now.isFinite, now >= 0 else {
            throw PumpError.rejected("先核对实体设备及设备自身的停止/卸力方式")
        }
        permit = Permit(slot:slot, device:device, packet:strength.packet, started:now)
    }
    public func isAuthorized(slot: String, peripheralID: String, now: TimeInterval) -> Bool {
        guard let permit, now.isFinite, now >= permit.started, now-permit.started < 60 else { return false }
        return slot == permit.slot && UUID(uuidString:peripheralID) == permit.device
    }
    /// Consume before recording/writing, including invalid attempts and sink failure.
    /// Native transport calls this exact path; neither closure retries a command.
    public mutating func performWrite(slot: String, peripheralID: String, strength: PumpStrength, now: TimeInterval,
                                      record: () throws -> Void, write: (Data) -> Void) throws {
        let approved = isAuthorized(slot:slot, peripheralID:peripheralID, now:now) && permit?.packet == strength.packet
        revoke()
        guard approved else { throw PumpError.rejected("原生许可缺失、已失效或设备/参数已改变，请重新核对") }
        try record()
        write(strength.packet)
    }
}

/// Exactly one software completion; invoking a writer is not device acceptance.
public struct PumpCommandOutcome {
    private var writerInvoked = false
    private var completed = false
    public init() {}
    public mutating func markWriterInvoked() { if !completed { writerInvoked = true } }
    public mutating func complete(hasError: Bool) -> String? {
        guard !completed else { return nil }
        completed = true
        return !writerInvoked ? "not_sent" : hasError ? "unknown" : "response_unverified"
    }
}
