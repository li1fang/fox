import Foundation

// Wire values only. Native owns recording; offline validation verifies the sealed package.
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
    enum CodingKeys: String, CodingKey {
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
    enum CodingKeys: String, CodingKey {
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
    enum CodingKeys: String, CodingKey {
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
    enum CodingKeys: String, CodingKey {
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
    enum CodingKeys: String, CodingKey {
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
}
