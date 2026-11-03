import Foundation

/// Nominal Pro settings from manufacturer specification, not calibrated force.
public enum PumpMachineProfile {
    case pumpPro
    public var maximum: Double { 20 }
    public func minimum(_ mode: PumpMode) -> Double { [.eccentric,.concentric].contains(mode) ? 5 : 2 }
}

public enum PumpLegResult: String {
    case notSent = "not_sent", responseUnverified = "response_unverified", unknown
    case gattAckUnverified = "gatt_ack_unverified"
    public var acknowledged: Bool { self == .responseUnverified || self == .gattAckUnverified }
}
public enum PumpGroupStatus: String {
    case notSent = "not_sent", bothResponseUnverified = "both_response_unverified", partial, unknown
    case persistenceFailed = "persistence_failed"
    case bothAcknowledgedUnverified = "both_acknowledged_unverified"
}
public struct PumpGroupRequest {
    public let id: String
    public let devices: [String:String]
    public let strength: PumpStrength
    public init(id: String, devices: [String:String], strength: PumpStrength) throws {
        guard id.range(of:"^[A-Za-z0-9_-]{8,64}$",options:.regularExpression) != nil,
              let pair = PumpRememberedPair.validated(devices) else { throw PumpError.rejected("需要两个不同的已登记设备及新请求ID") }
        _ = try PumpStrength(mode:strength.mode,kg:strength.kg,reduction:strength.reduction,profile:.pumpPro)
        self.id=id; self.devices=pair; self.strength=strength
    }
}
public struct PumpGroupResult {
    public let id: String
    public var devices: [String:PumpLegResult] = ["A":.notSent,"B":.notSent]
    public var notes = [String]()
    public var persistenceFailed = false
    public let physicalConfirmed = false
    public var status: PumpGroupStatus {
        if persistenceFailed { return .persistenceFailed }
        if devices.values.contains(.unknown) { return .unknown }
        if devices.values.allSatisfy({$0 == .responseUnverified}) { return .bothResponseUnverified }
        if devices.values.allSatisfy({$0.acknowledged}) { return .bothAcknowledgedUnverified }
        if devices.values.allSatisfy({$0 == .notSent}) { return .notSent }
        return .partial
    }
    public var requiresRecovery: Bool { [.partial,.unknown,.persistenceFailed].contains(status) }
}

/// Sequential once-per-peer dispatch is deliberately not an atomic BLE commit.
/// A response is unverified; unknown/partial state stops, never retries/rolls back.
@MainActor public final class PumpGroupController {
    public private(set) var isRunning = false
    public private(set) var activeID: String?
    public private(set) var lastResult: PumpGroupResult?
    public private(set) var requiresRecovery = false
    private var usedIDs = Set<String>()
    private var cancelled = false
    public init() {}
    public func cancel() { if isRunning { cancelled = true } }
    public func acknowledgeRecovery() { if !isRunning { requiresRecovery = false } }
    public func run(_ request: PumpGroupRequest, pairConfirmed: Bool, stopConfirmed: Bool,
                    preflight: (String,String) throws -> Void,
                    record: (String,PumpGroupResult) throws -> Void,
                    send: (String,PumpStrength,String) async throws -> PumpLegResult) async throws -> PumpGroupResult {
        guard pairConfirmed, stopConfirmed, !isRunning, !requiresRecovery, !usedIDs.contains(request.id) else {
            throw PumpError.rejected("请确认这一对及设置；重复、在途或未核对的未知结果不能发送")
        }
        usedIDs.insert(request.id); isRunning=true; activeID=request.id; cancelled=false
        defer { isRunning=false; activeID=nil }
        var result=PumpGroupResult(id:request.id)
        func persist(_ phase: String) throws {
            do { try record(phase,result) }
            catch { result.persistenceFailed=true; throw error }
        }
        do {
            // Both peers must be ready before the first write, then each is
            // checked again immediately before its own write.
            for slot in ["A","B"] { try preflight(slot,request.devices[slot]!) }
            try persist("group_begin")
            for slot in ["A","B"] {
                if cancelled { result.notes.append("用户或生命周期取消，未发送余下设备"); break }
                try preflight(slot,request.devices[slot]!)
                do { result.devices[slot] = try await send(slot,request.strength,request.id+"-"+slot) }
                catch { result.devices[slot] = .unknown; result.notes.append(error.localizedDescription) }
                try persist("group_result_"+slot)
                if result.devices[slot]?.acknowledged != true { break }
            }
        } catch {
            result.notes.append(error.localizedDescription)
            // A preflight error means no new write. A throwing record is
            // classified separately below, without erasing prior device facts.
        }
        do { try persist("group_complete") }
        catch { result.persistenceFailed=true; result.notes.append("结果记录失败："+error.localizedDescription) }
        lastResult=result; requiresRecovery=result.requiresRecovery
        return result
    }
}

/// Pair identity only: no color, side, request, load or permission is remembered.
public enum PumpRememberedPair {
    public static func validated(_ pair: [String:String]) -> [String:String]? {
        guard Set(pair.keys) == ["A","B"], let a=pair["A"].flatMap(UUID.init(uuidString:)),
              let b=pair["B"].flatMap(UUID.init(uuidString:)), a != b else { return nil }
        return ["A":a.uuidString,"B":b.uuidString]
    }
    public static func decodeLog(_ data: Data) -> [String:String]? {
        var observed=[String:Set<String>]()
        for line in data.split(separator:10) {
            guard let row=(try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any],
                  row["event"] as? String == "notification", row["synthetic"] as? Bool != true,
                  let slot=row["slot"] as? String, ["A","B"].contains(slot),
                  let id=row["peripheral_id"] as? String, let uuid=UUID(uuidString:id) else { continue }
            observed[slot,default:[]].insert(uuid.uuidString)
        }
        guard observed["A"]?.count == 1, observed["B"]?.count == 1 else { return nil }
        return validated(["A":observed["A"]!.first!,"B":observed["B"]!.first!])
    }
}
