import Foundation

public enum PumpError: Error, LocalizedError {
    case rejected(String)
    public var errorDescription: String? { if case .rejected(let text) = self { return text }; return nil }
}

public enum PumpMode: String, CaseIterable, Codable { case standard, constant, eccentric, concentric }

/// Fixed by the native host, not a permission that WebKit can grant.
public enum PumpAccessPolicy: String {
    case readOnly = "read_only"
    case control
    public var allowsControl: Bool { self == .control }
    public func controlEnabled(_ requested: Bool, foreground: Bool) -> Bool {
        allowsControl && requested && foreground
    }
    public func validate(action: String) throws {
        if !allowsControl && ["arm", "command"].contains(action) {
            throw PumpError.rejected("本次为只读连接验证，禁止允许或发送阻力指令")
        }
    }
}

/// Setpoints only. These values are not measured cable forces.
public struct PumpStrength {
    public let mode: PumpMode
    public let kg: Double
    public let reduction: Int
    public init(mode: PumpMode, kg: Double, reduction: Int = 0, standardLimit: Int = 5, profile: PumpMachineProfile? = nil) throws {
        guard [5, 8].contains(standardLimit) else { throw PumpError.rejected("Invalid experiment limit") }
        let limit = profile?.maximum ?? (mode == .standard ? Double(standardLimit) : 5)
        let minimum = profile?.minimum(mode) ?? 2
        guard kg.isFinite, kg >= minimum, kg <= limit, kg == (kg * 10).rounded() / 10,
              [0,25,50].contains(reduction),
              ([PumpMode.eccentric,.concentric].contains(mode) || reduction == 0) else {
            throw PumpError.rejected("参数超出本模式实验范围")
        }
        self.mode = mode; self.kg = kg; self.reduction = reduction
    }
    public var packet: Data {
        let tags: [PumpMode: UInt8] = [.standard:1,.constant:7,.eccentric:5,.concentric:6]
        var bytes: [UInt8] = [0x54, 6, 2, tags[mode]!, UInt8((kg * 10).rounded())]
        if [.eccentric,.concentric].contains(mode) { bytes[1] = 7; bytes.append(UInt8(reduction)) }
        bytes.append(0 &- bytes.reduce(UInt8(0), &+))
        return Data(bytes)
    }
    public var json: [String:Any] { ["mode":mode.rawValue,"kg":kg,"reduction_pct":reduction] }
}

public struct PumpFrame {
    public let raw: Data
    public let tag: UInt8
    public let profileValid: Bool
    public let fields: [String:Any]
    public init(_ data: Data) throws {
        let b = Array(data)
        guard b.count >= 3, b[0] == 0x53, Int(b[1]) == b.count else {
            throw PumpError.rejected("Unsupported notification framing")
        }
        raw = data; tag = b[2]
        profileValid = b.reduce(UInt8(0), &+) == 0 && ((tag == 2 && b.count == 11) || (tag == 3 && b.count == 21))
        var values: [String:Any] = ["tag":Int(tag),"sum8":Int(b.reduce(UInt8(0), &+)),"interpretation":"upstream_hypothesis"]
        if tag == 2 && b.count == 11 {
            let states = [0:"launching",1:"working",2:"charging",3:"overheat",4:"too_fast",5:"low_power",6:"power_off",7:"battery_failure",16:"reverse_discharge",32:"abnormal_charging"]
            values.merge(["kind":"device_heartbeat","work_state":states[Int(b[3])] ?? "unknown", "work_state_raw":Int(b[3]),
                          "motor_temp_c":Int(b[4])-21,"board_temp_c":Int(b[5])-21,"battery_temp_c":Int(b[6])-21,
                          "battery_pct":Int(b[7]),"firmware_main":Int(b[8]),"firmware_sub":Int(b[9])]) { _, new in new }
        } else if tag == 3 && b.count == 21 {
            func le(_ range: Range<Int>) -> Int { range.enumerated().reduce(0) { $0 | (Int(b[$1.element]) << ($1.offset*8)) } }
            values.merge(["kind":"sports_heartbeat","cable_length_cm":Int(b[4]),"speed_raw_unverified":Int(b[5]),
                          "total_reps":le(6..<8),"total_distance_cm":le(8..<11),"total_energy_j_upstream":le(11..<14),
                          "tension_time_raw":le(14..<16),"power_raw_unverified":Int(b[16]),"recovery_raw_unverified":le(17..<20)]) { _, new in new }
        } else { values["kind"] = tag == 255 ? "response_uninterpreted" : "unknown" }
        fields = values
    }
}

extension Data {
    public var pumpHex: String { map { String(format:"%02x", $0) }.joined() }
}

/// A reusable monotonic permission gate, independent of Bluetooth and WebKit.
public struct PumpGate {
    public private(set) var deadline: TimeInterval = 0
    public private(set) var heartbeat: TimeInterval?
    public private(set) var sports: TimeInterval?
    public private(set) var working = false
    public init() {}
    public mutating func revoke() { deadline = 0 }
    public mutating func receive(heartbeat isHeartbeat: Bool, working: Bool? = nil, now: TimeInterval) {
        // A gap revokes old permission even when the new packet restores freshness.
        if !fresh(now) { revoke() }
        if isHeartbeat { heartbeat = now; self.working = working ?? false } else { sports = now }
        if !self.working { revoke() }
    }
    public func fresh(_ now: TimeInterval) -> Bool {
        guard let heartbeat, let sports else { return false }
        return now >= heartbeat && now >= sports && now-heartbeat <= 3 && now-sports <= 3 && working
    }
    public mutating func arm(now: TimeInterval) throws {
        guard fresh(now) else { revoke(); throw PumpError.rejected("等待新鲜工作心跳和运动通知") }
        deadline = now + 60
    }
    public mutating func consume(now: TimeInterval) throws {
        let valid = fresh(now) && deadline > now
        revoke()
        guard valid else { throw PumpError.rejected("先允许下一条指令；许可已失效") }
    }
    public mutating func reset() { self = PumpGate() }
}
