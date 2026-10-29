import Foundation

// Declared v1 object keys are checked when decoding; manifest semantics use validate().
// Native owns recording; offline validation also verifies the sealed package bytes.
public struct LabCaptureManifest: Codable, Equatable {
    public var schema: String
    public var captureID: String
    public var hostClockID: String
    public var mode: String
    public var action: String?
    public var side: String?
    public var strategy: String?
    public var startedHostNS: String
    public var endedHostNS: String
    public var utcAnchor: LabUTCAnchor?
    public var streams: [LabCaptureStream]
    public var files: [LabCaptureAsset]
    public init(schema: String, captureID: String, hostClockID: String, mode: String, action: String? = nil, side: String? = nil, strategy: String? = nil, startedHostNS: String, endedHostNS: String, utcAnchor: LabUTCAnchor? = nil, streams: [LabCaptureStream], files: [LabCaptureAsset]) {
        self.schema = schema
        self.captureID = captureID
        self.hostClockID = hostClockID
        self.mode = mode
        self.action = action
        self.side = side
        self.strategy = strategy
        self.startedHostNS = startedHostNS
        self.endedHostNS = endedHostNS
        self.utcAnchor = utcAnchor
        self.streams = streams
        self.files = files
    }
    public init(from decoder: Decoder) throws {
        try requireDeclaredLabKeys(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schema: try c.decode(String.self, forKey: .schema), captureID: try c.decode(String.self, forKey: .captureID),
            hostClockID: try c.decode(String.self, forKey: .hostClockID), mode: try c.decode(String.self, forKey: .mode),
            action: try c.decodeIfPresent(String.self, forKey: .action), side: try c.decodeIfPresent(String.self, forKey: .side),
            strategy: try c.decodeIfPresent(String.self, forKey: .strategy), startedHostNS: try c.decode(String.self, forKey: .startedHostNS),
            endedHostNS: try c.decode(String.self, forKey: .endedHostNS), utcAnchor: try c.decodeIfPresent(LabUTCAnchor.self, forKey: .utcAnchor),
            streams: try c.decode([LabCaptureStream].self, forKey: .streams), files: try c.decode([LabCaptureAsset].self, forKey: .files))
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema = "schema"
        case captureID = "capture_id"
        case hostClockID = "host_clock_id"
        case mode = "mode"
        case action = "action"
        case side = "side"
        case strategy = "strategy"
        case startedHostNS = "started_host_ns"
        case endedHostNS = "ended_host_ns"
        case utcAnchor = "utc_anchor"
        case streams = "streams"
        case files = "files"
    }
}

public struct LabCaptureStream: Codable, Equatable {
    public var id: String
    public var kind: String
    public var state: String
    public var reason: String?
    public var recordSchema: String
    public var source: LabCaptureSource
    public init(id: String, kind: String, state: String, reason: String? = nil, recordSchema: String, source: LabCaptureSource) {
        self.id = id
        self.kind = kind
        self.state = state
        self.reason = reason
        self.recordSchema = recordSchema
        self.source = source
    }
    public init(from decoder: Decoder) throws {
        try requireDeclaredLabKeys(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), kind: try c.decode(String.self, forKey: .kind),
            state: try c.decode(String.self, forKey: .state), reason: try c.decodeIfPresent(String.self, forKey: .reason),
            recordSchema: try c.decode(String.self, forKey: .recordSchema), source: try c.decode(LabCaptureSource.self, forKey: .source))
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id = "id"
        case kind = "kind"
        case state = "state"
        case reason = "reason"
        case recordSchema = "record_schema"
        case source = "source"
    }
}

public struct LabCaptureAsset: Codable, Equatable {
    public var path: String
    public var bytes: Int64
    public var sha256: String
    public var streamID: String
    public init(path: String, bytes: Int64, sha256: String, streamID: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
        self.streamID = streamID
    }
    public init(from decoder: Decoder) throws {
        try requireDeclaredLabKeys(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try c.decode(String.self, forKey: .path), bytes: try c.decode(Int64.self, forKey: .bytes),
            sha256: try c.decode(String.self, forKey: .sha256), streamID: try c.decode(String.self, forKey: .streamID))
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case path = "path"
        case bytes = "bytes"
        case sha256 = "sha256"
        case streamID = "stream_id"
    }
}

public struct LabCaptureSource: Codable, Equatable {
    public var producer: String
    public var version: String
    public var clockID: String
    public var sourceID: String?
    public var deviceAlias: String?
    public var coordinateSystem: String?
    public var unit: String?
    public init(producer: String, version: String, clockID: String, deviceAlias: String? = nil, coordinateSystem: String? = nil, unit: String? = nil, sourceID: String? = nil) {
        self.producer = producer
        self.version = version
        self.clockID = clockID
        self.sourceID = sourceID
        self.deviceAlias = deviceAlias
        self.coordinateSystem = coordinateSystem
        self.unit = unit
    }
    public init(from decoder: Decoder) throws {
        try requireDeclaredLabKeys(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(producer: try c.decode(String.self, forKey: .producer), version: try c.decode(String.self, forKey: .version),
            clockID: try c.decode(String.self, forKey: .clockID), deviceAlias: try c.decodeIfPresent(String.self, forKey: .deviceAlias),
            coordinateSystem: try c.decodeIfPresent(String.self, forKey: .coordinateSystem), unit: try c.decodeIfPresent(String.self, forKey: .unit),
            sourceID: try c.decodeIfPresent(String.self, forKey: .sourceID))
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case producer = "producer"
        case version = "version"
        case clockID = "clock_id"
        case sourceID = "source_id"
        case deviceAlias = "device_alias"
        case coordinateSystem = "coordinate_system"
        case unit = "unit"
    }
}

public struct LabUTCAnchor: Codable, Equatable {
    public var hostNS: String
    public var utcUS: String
    public var uncertaintyUS: String
    public var method: String
    public init(hostNS: String, utcUS: String, uncertaintyUS: String, method: String) {
        self.hostNS = hostNS
        self.utcUS = utcUS
        self.uncertaintyUS = uncertaintyUS
        self.method = method
    }
    public init(from decoder: Decoder) throws {
        try requireDeclaredLabKeys(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(hostNS: try c.decode(String.self, forKey: .hostNS), utcUS: try c.decode(String.self, forKey: .utcUS),
            uncertaintyUS: try c.decode(String.self, forKey: .uncertaintyUS), method: try c.decode(String.self, forKey: .method))
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case hostNS = "host_ns"
        case utcUS = "utc_us"
        case uncertaintyUS = "uncertainty_us"
        case method = "method"
    }
}

public struct LabRationalTime: Codable, Equatable {
    public var value: String
    public var timescale: Int32
    public var epoch: String?
    public init(value: String, timescale: Int32, epoch: String? = nil) {
        self.value = value
        self.timescale = timescale
        self.epoch = epoch
    }
    enum CodingKeys: String, CodingKey {
        case value = "value"
        case timescale = "timescale"
        case epoch = "epoch"
    }
}

/// Original CMTime components remain strings/Int32; normalized seconds are a separate value.
public struct LabFrameRecord: Codable, Equatable {
    public var schema = "fox.lab_frame.v1"
    public let seq: UInt64
    public let pts: LabRationalTime
    public let originPTS: LabRationalTime
    public let videoSeconds: Double
    public let hostReceivedNS: String
    public let state: String
    public let reason: String?
    public init(seq: UInt64, pts: LabRationalTime, originPTS: LabRationalTime, videoSeconds: Double,
                hostReceivedNS: UInt64, state: String, reason: String?) {
        self.seq = seq; self.pts = pts; self.originPTS = originPTS; self.videoSeconds = videoSeconds
        self.hostReceivedNS = String(hostReceivedNS); self.state = state; self.reason = reason
    }
    enum CodingKeys: String, CodingKey {
        case schema, seq, pts, state, reason
        case originPTS = "origin_pts", videoSeconds = "video_seconds", hostReceivedNS = "host_received_ns"
    }
    private func validateReason() throws {
        if let reason, reason.isEmpty || reason.unicodeScalars.count > 512 {
            throw LabCaptureWireError.invalidFrameReason
        }
        if state == "dropped", reason == nil { throw LabCaptureWireError.invalidFrameReason }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        seq = try c.decode(UInt64.self, forKey: .seq)
        pts = try c.decode(LabRationalTime.self, forKey: .pts)
        originPTS = try c.decode(LabRationalTime.self, forKey: .originPTS)
        videoSeconds = try c.decode(Double.self, forKey: .videoSeconds)
        hostReceivedNS = try c.decode(String.self, forKey: .hostReceivedNS)
        state = try c.decode(String.self, forKey: .state)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        try validateReason()
    }
    public func encode(to encoder: Encoder) throws {
        try validateReason()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(seq, forKey: .seq)
        try c.encode(pts, forKey: .pts)
        try c.encode(originPTS, forKey: .originPTS)
        try c.encode(videoSeconds, forKey: .videoSeconds)
        try c.encode(hostReceivedNS, forKey: .hostReceivedNS)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(reason, forKey: .reason)
    }

}

public enum LabCaptureWireError: Error { case invalidFrameReason }

private struct LabContractKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireDeclaredLabKeys<K: CodingKey & CaseIterable>(_ decoder: Decoder, _ keys: K.Type) throws {
    let actual = try decoder.container(keyedBy: LabContractKey.self)
    let declared = Set(K.allCases.map(\.stringValue))
    guard actual.allKeys.allSatisfy({ declared.contains($0.stringValue) }) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown field in lab v1 object"))
    }
}
