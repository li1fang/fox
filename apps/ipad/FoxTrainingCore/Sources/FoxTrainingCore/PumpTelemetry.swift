import Foundation

/// Observed inbound profile only. No command encoding or SI calibration is provided.
public struct PumpTelemetryReading: Codable, Equatable {
    public var profile = "fox.pump_inbound_observed.v1"
    public var state: String
    public var reason: String?
    public var rawHex: String
    public var checksumPass: Bool?
    public var kind: String
    public var fields: [String: Int]
    enum CodingKeys: String, CodingKey {
        case profile, state, reason, kind, fields
        case rawHex = "raw_hex", checksumPass = "checksum_pass"
    }
    public static func decode(_ data: Data) -> Self {
        let bytes = Array(data)
        var result = Self(state: "quarantined", reason: nil, rawHex: bytes.map { String(format: "%02x", $0) }.joined(),
                          checksumPass: nil, kind: "unknown", fields: [:])
        guard bytes.count <= 512 else { result.reason = "oversize_notification"; return result }
        guard bytes.count >= 4 else { result.reason = "short_frame"; return result }
        result.checksumPass = bytes.reduce(0) { ($0 + Int($1)) & 255 } == 0
        guard bytes[0] == 0x53 else { result.reason = "unexpected_header"; return result }
        guard Int(bytes[1]) == bytes.count else { result.reason = "length_mismatch"; return result }
        guard result.checksumPass == true else { result.reason = "checksum_mismatch"; return result }
        let tag = bytes[2]
        guard tag == 2 || tag == 3 else { result.state = "unsupported"; result.reason = "unsupported_type"; return result }
        guard bytes.count == (tag == 2 ? 11 : 21) else { result.reason = "unsupported_profile_length"; return result }
        func little(_ start: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | (Int(bytes[start + $1]) << (8 * $1)) }
        }
        if tag == 2 {
            result.kind = "device_heartbeat"
            result.fields = ["work_state_raw": Int(bytes[3]), "motor_temperature_c_upstream": Int(bytes[4])-21,
                "board_temperature_c_upstream": Int(bytes[5])-21, "battery_temperature_c_upstream": Int(bytes[6])-21,
                "battery_percent_raw": Int(bytes[7]), "firmware_main_raw": Int(bytes[8]), "firmware_sub_raw": Int(bytes[9])]
        } else {
            result.kind = "sports_heartbeat"
            result.fields = ["unknown_3_raw": Int(bytes[3]), "cable_length_raw": Int(bytes[4]), "speed_raw": Int(bytes[5]),
                "repetitions_raw": little(6, 2), "distance_raw": little(8, 3), "energy_raw": little(11, 3),
                "tension_time_raw": little(14, 2), "power_raw": Int(bytes[16]), "recovery_raw": little(17, 3)]
        }
        result.state = "decoded"
        return result
    }
}

public struct PumpNotificationEvent: Codable, Equatable {
    public var schema = "fox.lab_pump_notification.v1"
    public let captureID: String
    public let deviceAlias: String
    public let connectionSegmentID: String
    public let hostClockID: String
    public let notificationSeq: UInt64
    public let hostReceivedNS: String
    public var deviceTick: String? = nil
    public let decoded: PumpTelemetryReading
    public init(captureID: String, deviceAlias: String, connectionSegmentID: String, hostClockID: String,
                notificationSeq: UInt64, hostReceivedNS: UInt64, bytes: Data) {
        self.captureID = captureID; self.deviceAlias = deviceAlias; self.connectionSegmentID = connectionSegmentID
        self.hostClockID = hostClockID; self.notificationSeq = notificationSeq; self.hostReceivedNS = String(hostReceivedNS)
        decoded = .decode(bytes)
    }
    enum CodingKeys: String, CodingKey {
        case schema, decoded
        case captureID = "capture_id", deviceAlias = "device_alias", connectionSegmentID = "connection_segment_id"
        case hostClockID = "host_clock_id", notificationSeq = "notification_seq", hostReceivedNS = "host_received_ns", deviceTick = "device_tick"
    }
}

public struct PumpConnectionEvent: Codable, Equatable {
    public var schema = "fox.lab_pump_connection.v1"
    public let captureID: String
    public let deviceAlias: String
    public let connectionSegmentID: String
    public let hostClockID: String
    public let hostReceivedNS: String
    public let state: String
    public let reason: String?
    public init(captureID: String, deviceAlias: String, connectionSegmentID: String, hostClockID: String,
                hostReceivedNS: UInt64, state: String, reason: String?) {
        self.captureID = captureID; self.deviceAlias = deviceAlias; self.connectionSegmentID = connectionSegmentID
        self.hostClockID = hostClockID; self.hostReceivedNS = String(hostReceivedNS); self.state = state; self.reason = reason
    }
    enum CodingKeys: String, CodingKey {
        case schema, state, reason
        case captureID = "capture_id", deviceAlias = "device_alias", connectionSegmentID = "connection_segment_id"
        case hostClockID = "host_clock_id", hostReceivedNS = "host_received_ns"
    }
}

/// Tracks only a subscription requested by this consumer, including a pending request.
/// An already-notifying characteristic belongs to another consumer and is refused.
public struct PumpNotificationSubscription {
    public private(set) var ownsSubscription = false
    public init() {}
    /// Never take over an existing peripheral consumer or its notification state.
    public static func adoptionRejection(hasExistingDelegate: Bool, alreadyNotifying: Bool) -> String? {
        if alreadyNotifying { return "existing_subscription" }
        if hasExistingDelegate { return "existing_delegate" }
        return nil
    }
    public mutating func requestNewSubscription(alreadyNotifying: Bool) -> Bool {
        guard !ownsSubscription, !alreadyNotifying else { return false }
        ownsSubscription = true
        return true
    }
    /// True means the caller may cancel its own request; repeated release is inert.
    public mutating func release() -> Bool {
        let owned = ownsSubscription
        ownsSubscription = false
        return owned
    }
}
