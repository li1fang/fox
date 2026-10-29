import AVFoundation
import Foundation
import FoxTrainingCore

/// Permanent experimental originals. This directory is never passed to diagnostic draft pruning.
final class FreeCaptureArchive {
    private struct Context: Codable {
        var schema = "fox.lab_context.v1"
        var captureID: UUID
        var sourceID: String
        var processID: UUID
        var startedHostNS: String
        var recordedAt: Date
        var frontCamera: Bool
        var analysis: String
        var pumpRequested: Bool
        var pixelOrientation = "up-already-applied"
        var pixelsMirrored = false
        var audio = false
        var maximumSeconds = 300
        var dataClass: String
        var pumpAliases: [String] = []
        var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        var appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    }
    static let processID = UUID()
    private static let recoveryLock = NSLock()
    private static let initializationLock = NSLock()
    private static var initializingFolders = Set<String>()
    private static func setInitializing(_ path: String, begin: Bool) -> Bool {
        initializationLock.lock(); defer { initializationLock.unlock() }
        if begin { return initializingFolders.insert(path).inserted }
        initializingFolders.remove(path); return true
    }
    private static func isInitializing(_ path: String) -> Bool {
        initializationLock.lock(); defer { initializationLock.unlock() }; return initializingFolders.contains(path)
    }
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1" ? "FoxLabCaptureFixtures" : "FoxLabCaptures")
    }
    let id: UUID
    let folder: URL
    let sourceID: String
    let clockID: String
    private let context: Context
    private var logs: [String: FileHandle] = [:]
    private var sealed = false
    private var lastFramePTS: CMTime?
    private var analysisIssues: [String: String] = [:]
    private var analysisRows: [String: Int] = [:]
    private var sensorState = "not_requested"
    private var sensorReason: String?
    private var pumpStates: [String: String] = [:]
    private var pumpReasons: [String: String] = [:]
    private var pumpHasData = Set<String>()
    private var pumpInterrupted = Set<String>()

    init(id: UUID, options: FreeCaptureOptions, root: URL, synthetic: Bool = false, pumpAliases: [String] = []) throws {
        guard Set(pumpAliases).count == pumpAliases.count, pumpAliases.count <= 2,
              pumpAliases.allSatisfy({ ["pump-A", "pump-B"].contains($0) }), options.pumpEnabled || pumpAliases.isEmpty else {
            throw VisionDiagnosticArchive.error("PUMP 采集别名无效。")
        }
        self.id = id; sourceID = UUID().uuidString; clockID = "host-\(Self.processID.uuidString)"
        context = Context(captureID: id, sourceID: sourceID, processID: Self.processID,
                          startedHostNS: String(DispatchTime.now().uptimeNanoseconds), recordedAt: Date(),
                          frontCamera: options.frontCamera, analysis: options.analysis.rawValue, pumpRequested: options.pumpEnabled,
                          dataClass: synthetic ? "synthetic" : "recorded", pumpAliases: pumpAliases)
        folder = root.appendingPathComponent(id.uuidString)
        guard Self.setInitializing(folder.path, begin: true) else { throw VisionDiagnosticArchive.error("采集 ID 正在初始化，未覆盖。") }
        defer { _ = Self.setInitializing(folder.path, begin: false) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else { throw VisionDiagnosticArchive.error("实验根目录不是普通目录。") }
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw VisionDiagnosticArchive.error("采集 ID 已存在，未覆盖。") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Self.encode(context).write(to: folder.appendingPathComponent("context.json"), options: .atomic)
        var names = ["frames.jsonl", "events.jsonl"]
        if options.analysis != .none { names.append("poses2d.jsonl") }
        if options.analysis == .comparison { names.append("poses3d.jsonl") }
        if options.pumpEnabled { sensorState = "unavailable"; sensorReason = "no_device_selected" }
        for alias in pumpAliases {
            names.append("\(alias).jsonl"); pumpStates[alias] = "interrupted"; pumpReasons[alias] = "not_connected_or_no_data"
        }
        for name in names {
            guard FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil) else {
                throw VisionDiagnosticArchive.error("无法创建采集日志，现有文件保留。")
            }
            logs[name] = try FileHandle(forWritingTo: folder.appendingPathComponent(name))
        }
        try event("capture_requested")
    }
    deinit { for handle in logs.values { try? handle.close() } }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    private func line(_ bytes: Data, name: String) throws {
        guard !sealed, let log = logs[name] else { throw VisionDiagnosticArchive.error("采集日志已关闭。") }
        try log.write(contentsOf: bytes); try log.write(contentsOf: Data([10]))
    }
    func event(_ kind: String, reason: String? = nil) throws {
        var value: [String: Any] = ["schema": "fox.lab_event.v1", "capture_id": id.uuidString,
                                    "host_received_ns": String(DispatchTime.now().uptimeNanoseconds), "kind": kind]
        if let reason { value["reason"] = reason }
        try line(JSONSerialization.data(withJSONObject: value, options: .sortedKeys), name: "events.jsonl")
    }
    func frame(_ frame: FreeCaptureVideoWriter.Frame, seq: Int, hostNS: UInt64, origin: CMTime) throws {
        guard let relative = frame.videoTime, relative.seconds >= 0,
              lastFramePTS.map({ CMTimeCompare(frame.capturePTS, $0) >= 0 }) ?? true else {
            try event("non_monotonic_camera_pts", reason: "capture_pts=\(frame.capturePTS.value)/\(frame.capturePTS.timescale)")
            return
        }
        let value = LabFrameRecord(seq: UInt64(seq),
            pts: .init(value: String(frame.capturePTS.value), timescale: frame.capturePTS.timescale, epoch: String(frame.capturePTS.epoch)),
            originPTS: .init(value: String(origin.value), timescale: origin.timescale, epoch: String(origin.epoch)),
            videoSeconds: relative.seconds, hostReceivedNS: hostNS, state: frame.encoded ? "observed" : "dropped", reason: frame.reason)
        try line(Self.encode(value), name: "frames.jsonl")
        lastFramePTS = frame.capturePTS
    }
    func pose(_ bytes: Data, kind: String, issue: String? = nil) throws {
        guard kind == "pose2d" || kind == "pose3d" else { throw VisionDiagnosticArchive.error("姿态流类型无效。") }
        if let issue { analysisIssues[kind] = issue }
        try line(bytes, name: kind == "pose2d" ? "poses2d.jsonl" : "poses3d.jsonl")
        analysisRows[kind, default: 0] += 1
    }
    func noteAnalysisIssue(_ kind: String, reason: String) { analysisIssues[kind] = reason }
    func acceptsPump(captureID: String, clockID: String, alias: String) -> Bool {
        captureID == id.uuidString && clockID == self.clockID && context.pumpAliases.contains(alias)
    }
    func pump(_ value: PumpNotificationEvent) throws {
        guard value.captureID == id.uuidString, value.hostClockID == clockID, context.pumpAliases.contains(value.deviceAlias) else {
            throw VisionDiagnosticArchive.error("PUMP 通知不属于本次采集。")
        }
        try line(Self.encode(value), name: "\(value.deviceAlias).jsonl")
        pumpHasData.insert(value.deviceAlias)
        if !pumpInterrupted.contains(value.deviceAlias) { pumpStates[value.deviceAlias] = "complete"; pumpReasons.removeValue(forKey: value.deviceAlias) }
    }
    func pump(_ value: PumpConnectionEvent) throws {
        guard value.captureID == id.uuidString, value.hostClockID == clockID, context.pumpAliases.contains(value.deviceAlias) else {
            throw VisionDiagnosticArchive.error("PUMP 状态不属于本次采集。")
        }
        try line(Self.encode(value), name: "\(value.deviceAlias).jsonl")
        if value.state == "failed" || (value.state == "disconnected" && value.reason != "user_stopped") {
            pumpInterrupted.insert(value.deviceAlias)
            pumpStates[value.deviceAlias] = "interrupted"; pumpReasons[value.deviceAlias] = value.reason ?? value.state
        } else if value.state == "disconnected", !pumpHasData.contains(value.deviceAlias) {
            pumpStates[value.deviceAlias] = "interrupted"; pumpReasons[value.deviceAlias] = pumpReasons[value.deviceAlias] ?? "no_notifications"
        }
    }
    func seal(video: FreeCaptureVideoWriter.Summary?, reason: String, videoError: String? = nil,
              encodedFrames: Int? = nil, droppedFrames: Int? = nil, recoveredEndHostNS: String? = nil) throws -> FreeCapturePackageSummary {
        guard !sealed else { throw VisionDiagnosticArchive.error("采集已封存，未覆盖。") }
        if recoveredEndHostNS == nil { try event("capture_ended", reason: reason) }
        sealed = true
        for handle in logs.values { try handle.synchronize(); try handle.close() }
        logs = [:]
        let interrupted = !["userStopped", "durationLimit", "sizeLimit"].contains(reason)
        let state = video == nil ? "failed" : (interrupted ? "interrupted" : "complete")
        let summary = FreeCapturePackageSummary(id: id, folder: folder, recordedAt: context.recordedAt,
            videoAvailable: video != nil, recordingState: state, encodedFrames: video?.encodedFrames ?? encodedFrames, droppedFrames: video?.droppedFrames ?? droppedFrames,
            synthetic: context.dataClass == "synthetic", stopReason: reason)
        var details: [String: Any] = ["schema": "fox.lab_recording.v1", "capture_id": id.uuidString,
            "recording_state": state, "stop_reason": reason, "video_available": summary.videoAvailable]
        if let count = summary.encodedFrames { details["encoded_frames"] = count }
        if let count = summary.droppedFrames { details["dropped_frames"] = count }
        if let video {
            details["first_pts"] = ["value": String(video.firstPTS.value), "timescale": video.firstPTS.timescale]
            details["last_pts"] = ["value": String(video.lastPTS.value), "timescale": video.lastPTS.timescale]
            details["width"] = video.width; details["height"] = video.height
        }
        if let videoError { details["video_error"] = videoError }
        if recoveredEndHostNS != nil { details["end_boundary"] = "last_saved_host_timestamp_not_observed_stop" }
        try JSONSerialization.data(withJSONObject: details, options: .sortedKeys).write(to: folder.appendingPathComponent("recording.json"), options: .atomic)
        var streams: [LabCaptureStream] = []
        let source = LabCaptureSource(producer: context.dataClass == "synthetic" ? "fox_synthetic_capture" : "fox_ios_capture", version: "1", clockID: clockID, sourceID: sourceID)
        streams.append(.init(id: "video", kind: "video", state: state, reason: state == "complete" ? nil : (videoError ?? reason), recordSchema: "video/h264", source: source))
        let recovered = recoveredEndHostNS != nil
        streams.append(.init(id: "frames", kind: "camera_frames", state: state, reason: state == "complete" ? nil : reason,
                             recordSchema: recovered ? "fox.lab_recovered_raw.v1" : "fox.lab_frame.v1", source: source))
        streams.append(.init(id: "events", kind: "events", state: recovered ? "interrupted" : "complete", reason: recovered ? "process_ended" : nil,
                             recordSchema: recovered ? "fox.lab_recovered_raw.v1" : "fox.lab_event.v1", source: source))
        streams.append(.init(id: "context", kind: "events", state: "complete", recordSchema: "fox.lab_context.v1", source: source))
        streams.append(.init(id: "recording", kind: "events", state: "complete", recordSchema: "fox.lab_recording.v1", source: source))
        for kind in ["pose2d", "pose3d"] {
            let requested = kind == "pose2d" ? context.analysis != FreeCaptureAnalysis.none.rawValue : context.analysis == FreeCaptureAnalysis.comparison.rawValue
            let issue = analysisIssues[kind] ?? (requested && analysisRows[kind, default: 0] == 0 ? "no_analysis_frames" : nil)
            streams.append(.init(id: kind, kind: kind, state: requested ? (issue == nil ? "complete" : "interrupted") : "not_requested", reason: issue,
                recordSchema: recovered && requested ? "fox.lab_recovered_raw.v1" : (kind == "pose2d" ? "fox.lab_pose2d.v1" : "fox.pose3d_frame.v1"),
                source: .init(producer: kind == "pose2d" ? "apple_vision_body_pose_2d" : "apple_vision_body_pose_3d", version: "1", clockID: clockID,
                              coordinateSystem: kind == "pose2d" ? "normalized_image_bottom_left_anatomical_sides" : "apple_vision_root_relative_model", unit: kind == "pose2d" ? "normalized" : "model_meters_height_source_per_observation", sourceID: sourceID)))
        }
        if context.pumpAliases.isEmpty {
            streams.append(.init(id: "pump", kind: "pump_raw", state: sensorState, reason: sensorReason,
                                 recordSchema: "fox.lab_pump_events.v1", source: .init(producer: "pump_ble_notification", version: "1", clockID: clockID)))
        } else {
            for alias in context.pumpAliases {
                streams.append(.init(id: alias, kind: "pump_raw", state: pumpStates[alias] ?? "interrupted", reason: pumpReasons[alias],
                    recordSchema: recovered ? "fox.lab_recovered_raw.v1" : "fox.lab_pump_events.v1",
                    source: .init(producer: "pump_ble_notification", version: "1", clockID: clockID, deviceAlias: alias)))
            }
        }
        var mapping = ["context.json": "context", "recording.json": "recording", "events.jsonl": "events", "frames.jsonl": "frames",
                       "video.mp4": "video", "video.partial.mp4": "video", "poses2d.jsonl": "pose2d", "poses3d.jsonl": "pose3d"]
        for alias in context.pumpAliases { mapping["\(alias).jsonl"] = alias }
        var files: [LabCaptureAsset] = []
        for name in mapping.keys.sorted() where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            let asset = try VisionDiagnosticArchive.asset(folder.appendingPathComponent(name))
            files.append(.init(path: name, bytes: asset.bytes, sha256: asset.sha256, streamID: mapping[name]!))
        }
        let manifest = LabCaptureManifest(schema: "fox.lab_capture.v1", captureID: id.uuidString, hostClockID: clockID, mode: "free_capture",
            startedHostNS: context.startedHostNS, endedHostNS: recoveredEndHostNS ?? String(DispatchTime.now().uptimeNanoseconds), streams: streams, files: files)
        let target = folder.appendingPathComponent("manifest.json")
        guard !FileManager.default.fileExists(atPath: target.path) else { throw VisionDiagnosticArchive.error("封包已存在，未覆盖。") }
        try Self.encode(manifest).write(to: target, options: .atomic)
        return summary
    }
    static func list(root: URL) throws -> [FreeCapturePackageSummary] {
        try library(root: root).packages
    }
    static func library(root: URL) throws -> (packages: [FreeCapturePackageSummary], issues: [String]) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], []) }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw VisionDiagnosticArchive.error("实验根目录不是普通目录。") }
        var packages: [FreeCapturePackageSummary] = [], issues: [String] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw VisionDiagnosticArchive.error("实验目录不是普通目录。") }
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            let manifestInfo = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard manifestInfo.isRegularFile == true, manifestInfo.isSymbolicLink != true, (manifestInfo.fileSize ?? Int.max) <= 1024 * 1024 else {
                throw VisionDiagnosticArchive.error("实验清单无效或过大。")
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(LabCaptureManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.schema == "fox.lab_capture.v1", manifest.captureID == id.uuidString else { throw VisionDiagnosticArchive.error("实验封包 ID 不匹配。") }
            try verifyAssets(manifest, folder: folder)
            let context = try decoder.decode(Context.self, from: Data(contentsOf: folder.appendingPathComponent("context.json")))
            guard context.schema == "fox.lab_context.v1", context.captureID == id else { throw VisionDiagnosticArchive.error("实验上下文 ID 不匹配。") }
            let details = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("recording.json"))) as? [String: Any]
            packages.append(FreeCapturePackageSummary(id: id, folder: folder, recordedAt: context.recordedAt,
                videoAvailable: details?["video_available"] as? Bool ?? false, recordingState: details?["recording_state"] as? String ?? "failed",
                encodedFrames: details?["encoded_frames"] as? Int, droppedFrames: details?["dropped_frames"] as? Int, synthetic: context.dataClass == "synthetic",
                stopReason: details?["stop_reason"] as? String))
            } catch { issues.append("\(id.uuidString)：\(error.localizedDescription)") }
        }
        return (packages, issues)
    }
    private static func verifyAssets(_ manifest: LabCaptureManifest, folder: URL) throws {
        guard manifest.files.count <= 256 else { throw VisionDiagnosticArchive.error("实验附件数量无效。") }
        var names = Set<String>()
        var total: Int64 = 0
        for file in manifest.files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.hasPrefix("/"), !file.path.contains("\\"), !file.path.contains("\0"),
                  !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), file.path != "manifest.json",
                  names.insert(file.path).inserted, file.bytes >= 0, file.bytes <= 512 * 1024 * 1024 else {
                throw VisionDiagnosticArchive.error("实验附件路径或大小无效，原件保留。")
            }
            if ["context.json", "recording.json"].contains(file.path), file.bytes > 1024 * 1024 { throw VisionDiagnosticArchive.error("实验元数据过大，原件保留。") }
            total += file.bytes
            guard total <= 2 * 1024 * 1024 * 1024 else { throw VisionDiagnosticArchive.error("实验封包超过完整性核对上限。") }
            // Check every component before hashing; a directory link cannot escape the package.
            var cursor = folder
            for part in parts {
                cursor.appendPathComponent(String(part))
                guard try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw VisionDiagnosticArchive.error("实验附件含链接，未读取。") }
            }
            let actual = try VisionDiagnosticArchive.asset(folder.appendingPathComponent(file.path))
            guard actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw VisionDiagnosticArchive.error("实验附件缺失或摘要不符，原件保留。") }
        }
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            throw VisionDiagnosticArchive.error("实验目录无法核对。")
        }
        var actualNames = Set<String>()
        for case let file as URL in items {
            let info = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw VisionDiagnosticArchive.error("实验目录含链接，未导出。") }
            if info.isDirectory == true { continue }
            let relative = String(file.path.dropFirst(folder.path.count + 1))
            if relative != "manifest.json" { actualNames.insert(relative) }
        }
        guard actualNames == names else { throw VisionDiagnosticArchive.error("实验文件与清单不一致，原件保留。") }
    }
    private init(context: Context, folder: URL) throws {
        self.context = context; self.folder = folder; id = context.captureID; sourceID = context.sourceID
        clockID = "host-\(context.processID.uuidString)"
        let url = folder.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url); _ = try handle.seekToEnd(); logs["events.jsonl"] = handle
        if context.analysis != FreeCaptureAnalysis.none.rawValue { analysisIssues["pose2d"] = "process_ended" }
        if context.analysis == FreeCaptureAnalysis.comparison.rawValue { analysisIssues["pose3d"] = "process_ended" }
        if context.pumpRequested { sensorState = "unavailable"; sensorReason = "process_ended" }
        for alias in context.pumpAliases { pumpStates[alias] = "interrupted"; pumpReasons[alias] = "process_ended" }
    }
    @discardableResult
    static func recover(root: URL, currentProcessID: UUID = processID) throws -> [String] {
        recoveryLock.lock(); defer { recoveryLock.unlock() }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw VisionDiagnosticArchive.error("实验恢复根目录不是普通目录。") }
        var issues: [String] = []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  !FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else { continue }
            if isInitializing(folder.path) { continue }
            do {
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw VisionDiagnosticArchive.error("实验恢复目录无效。") }
            let context = try decoder.decode(Context.self, from: Data(contentsOf: folder.appendingPathComponent("context.json")))
            guard context.captureID.uuidString == folder.lastPathComponent else { throw VisionDiagnosticArchive.error("恢复采集 ID 不匹配。") }
            guard context.processID != currentProcessID else { continue }
            let archive = try FreeCaptureArchive(context: context, folder: folder)
            // The next process may even be on a different boot clock. Never insert its
            // current uptime into the old capture. Bound recovery by original saved rows.
            var end = UInt64(context.startedHostNS) ?? 0
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw VisionDiagnosticArchive.error("恢复日志不是普通文件。") }
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                var buffer = Data()
                while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                           let text = object["host_received_ns"] as? String, let value = UInt64(text) { end = max(end, value) }
                    }
                    guard buffer.count <= 1024 * 1024 else { throw VisionDiagnosticArchive.error("恢复日志行过长，原件保留。") }
                }
                if !buffer.isEmpty, let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
                   let text = object["host_received_ns"] as? String, let value = UInt64(text) { end = max(end, value) }
            }
            _ = try archive.seal(video: nil, reason: "processEnded", videoError: "进程中断；现存文件保留，未确认完整视频或帧数。", recoveredEndHostNS: String(end))
            } catch { issues.append("\(folder.lastPathComponent)：\(error.localizedDescription)") }
        }
        return issues
    }
    static func remove(id: UUID, root: URL) throws {
        let folder = root.appendingPathComponent(id.uuidString)
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else { throw VisionDiagnosticArchive.error("只允许明确删除已封存的实验。") }
        try FileManager.default.removeItem(at: folder)
    }
}
