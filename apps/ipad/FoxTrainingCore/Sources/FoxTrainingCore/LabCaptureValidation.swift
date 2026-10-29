import Foundation

/// The v1 manifest contract, shared by Native sealing and library consumers.
/// Unknown record schemas remain preservable; file bytes are checked by the owner.
public extension LabCaptureManifest {
    func validate() throws {
        func require(_ condition: Bool, _ field: String) throws {
            if !condition { throw LabCaptureValidationError.invalidManifest(field) }
        }
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
        }
        func identity(_ value: String) -> Bool { matches(value, "[A-Za-z0-9][A-Za-z0-9._-]{0,127}") }
        func text(_ value: String) -> Bool { !value.isEmpty && value.unicodeScalars.count <= 512 }
        func decimal(_ value: String) -> Bool { matches(value, "0|[1-9][0-9]{0,24}") }
        try require(schema == "fox.lab_capture.v1", "schema")
        try require(identity(captureID) && identity(hostClockID), "capture/host identity")
        try require(["free_capture", "exercise_evaluation"].contains(mode), "mode")
        try require(action.map(text) ?? true, "action")
        try require(strategy.map(text) ?? true, "strategy")
        try require(side.map { ["left", "right", "both", "not_applicable"].contains($0) } ?? true, "side")
        try require(mode != "exercise_evaluation" || (action != nil && strategy != nil), "evaluation strategy")
        try require(decimal(startedHostNS) && decimal(endedHostNS), "host timestamps")
        try require(endedHostNS.count > startedHostNS.count || (endedHostNS.count == startedHostNS.count && endedHostNS >= startedHostNS), "host time order")
        if let anchor = utcAnchor {
            try require(decimal(anchor.hostNS) && decimal(anchor.utcUS) && decimal(anchor.uncertaintyUS) && text(anchor.method), "UTC anchor")
        }
        try require(streams.count <= 64 && files.count <= 256, "stream/file limits")
        var byID: [String: LabCaptureStream] = [:]
        for stream in streams {
            try require(identity(stream.id) && byID[stream.id] == nil, "stream identity")
            try require(["video", "camera_frames", "pose2d", "pose3d", "pump_raw", "pump_parsed", "events"].contains(stream.kind), "stream kind")
            try require(["complete", "interrupted", "failed", "unavailable", "not_requested"].contains(stream.state), "stream state")
            try require(text(stream.recordSchema) && (stream.reason.map(text) ?? true), "stream schema/reason")
            try require(!["interrupted", "failed", "unavailable"].contains(stream.state) || stream.reason != nil, "failure reason")
            let source = stream.source
            try require(text(source.producer) && text(source.version) && source.clockID == hostClockID, "stream host clock/source")
            try require(source.sourceID.map(identity) ?? true, "source identity")
            try require([source.deviceAlias, source.coordinateSystem, source.unit].allSatisfy { $0.map(text) ?? true }, "source metadata")
            if stream.recordSchema == "fox.lab_frame.v1" { try require(stream.kind == "camera_frames", "frame schema kind") }
            if stream.recordSchema == "fox.lab_pump_events.v1" { try require(stream.kind == "pump_raw", "PUMP schema kind") }
            byID[stream.id] = stream
        }
        var names = Set<String>(), counts: [String: Int] = [:], total: Int64 = 0
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            try require(text(file.path) && !file.path.contains("\\") && !file.path.contains("\0") && file.path != "manifest.json"
                        && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }, "asset path")
            try require(names.insert(file.path).inserted, "duplicate asset")
            try require(file.bytes >= 0 && file.bytes <= 512 * 1024 * 1024 && matches(file.sha256, "[0-9a-f]{64}"), "asset size/hash")
            guard let stream = byID[file.streamID] else { throw LabCaptureValidationError.invalidManifest("missing asset stream") }
            try require(!["not_requested", "unavailable"].contains(stream.state), "unavailable stream asset")
            counts[file.streamID, default: 0] += 1
            try require(counts[file.streamID] == 1, "one asset per stream")
            total += file.bytes
        }
        try require(total <= 2 * 1024 * 1024 * 1024, "total asset size")
        try require(streams.allSatisfy { $0.state != "complete" || counts[$0.id] == 1 }, "complete stream missing asset")
    }
}

public enum LabCaptureValidationError: Error, LocalizedError {
    case invalidManifest(String)
    public var errorDescription: String? {
        switch self { case .invalidManifest(let field): return "Invalid lab manifest: \(field)" }
    }
}
