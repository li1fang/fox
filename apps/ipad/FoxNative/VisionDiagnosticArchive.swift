import CryptoKit
import Foundation
import FoxTrainingCore

struct VisionDiagnosticContext: Codable {
    var schema = "fox.vision_diagnostic_context.v1"
    var id = UUID()
    var processToken = VisionDiagnosticArchive.processToken
    var startedAt = Date()
    var source: VisionInputSource
    var device: String
    var appVersion: String
    var appBuild: String
    var camera: String
    var exercise: VisionExercise
    var arm: ArmSide
    var bodyView: VisionBodyView
    var screenOrientation: VisionScreenOrientation
    var configuration: PoseCounterConfiguration
    var runtimePolicy: PoseRuntimePolicy
    var visionRevision = 1
    var audio = false
    var maximumSeconds = 300.0
    var workoutSessionID: UUID?
    var setAttemptID: UUID?
    var hardwareModel: String?
}

struct VisionDiagnosticManifest: Codable, Identifiable {
    struct Asset: Codable {
        var path: String
        var bytes: Int64
        var sha256: String
    }
    struct Video: Codable {
        var path = "video.mp4"
        var codec = "h264"
        var audio = false
        var width: Int
        var height: Int
        var firstCapturePTS: Double
        var lastCapturePTS: Double
        var encodedFrames: Int
        var droppedFrames: Int
    }
    var schema = "fox.vision_diagnostic_manifest.v1"
    var id: UUID
    var startedAt: Date
    var endedAt = Date()
    var source: VisionInputSource
    var state: String
    var stopReason: String
    var error: String?
    var video: Video?
    var files: [Asset]
    var automaticCount: Int?
    var storagePolicy: String?
    var retainedAt: Date?
}

/// A post-recording user annotation. It never changes captured events or automatic counts.
struct VisionDiagnosticReview: Codable {
    var schema = "fox.diagnostic_review.v1"
    var diagnosticID: UUID
    var reviewedAt: Date
    var referenceCount: Int?
    var review: TrialReview?
    func validate(id: UUID, endedAt: Date) throws {
        guard schema == "fox.diagnostic_review.v1", diagnosticID == id,
              reviewedAt.timeIntervalSince1970.isFinite, reviewedAt >= endedAt,
              referenceCount.map({ (0...10000).contains($0) }) ?? true else {
            throw VisionDiagnosticArchive.error("复核信息与本次诊断不匹配。")
        }
        try review?.validate()
    }
}

enum VisionDiagnosticArchive {
    static let processToken = UUID()
    static let names = ["context.json", "frames.jsonl", "poses.jsonl", "events.jsonl", "video.mp4", "video.partial.mp4", "review.json"]
    static func hardwareModel() -> String {
        var info = utsname(); uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    static var root: URL {
        let testing = ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(testing ? "FoxDiagnosticsFixtures" : "FoxDiagnostics")
    }
    static var draftRoot: URL {
        let testing = ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1"
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(testing ? "FoxDiagnosticFixtureDrafts" : "FoxDiagnosticDrafts")
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    static func error(_ message: String) -> NSError {
        NSError(domain: "FoxVisionDiagnostic", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func prepare(_ context: VisionDiagnosticContext, root: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(context.id.uuidString)
        guard !manager.fileExists(atPath: folder.path) else { throw error("诊断 ID 已存在，未覆盖。") }
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        var mutable = folder; try mutable.setResourceValues(resources)
        try encode(context).write(to: folder.appendingPathComponent("context.json"), options: .atomic)
        try Data("recording".utf8).write(to: folder.appendingPathComponent("status"), options: .atomic)
        return folder
    }
    static func asset(_ url: URL) throws -> VisionDiagnosticManifest.Asset {
        let resources = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard resources.isRegularFile == true, resources.isSymbolicLink != true else { throw error("诊断文件类型无效。") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return .init(path: url.lastPathComponent, bytes: Int64(resources.fileSize ?? 0),
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func seal(context: VisionDiagnosticContext, folder: URL, state: String, reason: String,
                     error message: String?, video: VisionDiagnosticManifest.Video?, automaticCount: Int? = nil) throws -> VisionDiagnosticManifest {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else { throw error("诊断已封存，未覆盖。") }
        let files = try names.compactMap { name -> VisionDiagnosticManifest.Asset? in
            let url = folder.appendingPathComponent(name)
            return manager.fileExists(atPath: url.path) ? try asset(url) : nil
        }
        let manifest = VisionDiagnosticManifest(id: context.id, startedAt: context.startedAt, source: context.source,
            state: state, stopReason: reason, error: message, video: video, files: files,
            automaticCount: automaticCount, storagePolicy: "temporary-until-review")
        try encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        try? manager.removeItem(at: folder.appendingPathComponent("status"))
        return manifest
    }
    static func list(root: URL, recovering: Bool = true) throws -> [VisionDiagnosticManifest] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        var results: [VisionDiagnosticManifest] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw error("诊断目录不是本机普通目录。") }
            let url = folder.appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let manifest = try decode(VisionDiagnosticManifest.self, at: url)
                guard manifest.id.uuidString == folder.lastPathComponent else { throw error("诊断 ID 不匹配。") }
                results.append(manifest)
            } else if recovering {
                let context = try decode(VisionDiagnosticContext.self, at: folder.appendingPathComponent("context.json"))
                if context.processToken != processToken {
                    results.append(try seal(context: context, folder: folder, state: "interrupted", reason: "processEnded",
                        error: "上次进程结束，视频可能未完成封装；不作为完整录像。", video: nil))
                }
            }
        }
        return results.sorted { $0.startedAt > $1.startedAt }
    }
    static func remove(id: UUID, root: URL) throws {
        let folder = root.appendingPathComponent(id.uuidString)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path),
              try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw error("只允许删除已封存的诊断。") }
        try FileManager.default.removeItem(at: folder)
    }
    static func retain(id: UUID, drafts: URL, destination: URL, review: VisionDiagnosticReview? = nil) throws -> VisionDiagnosticManifest {
        let manager = FileManager.default, folder = drafts.appendingPathComponent(id.uuidString)
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw error("临时诊断目录无效。") }
        var manifest = try decode(VisionDiagnosticManifest.self, at: folder.appendingPathComponent("manifest.json"))
        guard manifest.id == id, manifest.schema == "fox.vision_diagnostic_manifest.v1" else { throw error("临时诊断 ID 无效。") }
        try review?.validate(id: id, endedAt: manifest.endedAt)
        for expected in manifest.files {
            guard names.contains(expected.path) else { throw error("临时诊断含未知文件。") }
            let measured = try asset(folder.appendingPathComponent(expected.path))
            guard measured.bytes == expected.bytes, measured.sha256 == expected.sha256 else { throw error("临时诊断文件损坏，原件已保留。") }
        }
        let target = destination.appendingPathComponent(id.uuidString)
        guard !manager.fileExists(atPath: target.path) else { throw error("同 ID 已保留，未覆盖。") }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        if let review {
            let url = folder.appendingPathComponent("review.json")
            try encode(review).write(to: url, options: .atomic)
            manifest.files.removeAll { $0.path == "review.json" }
            manifest.files.append(try asset(url))
        }
        manifest.retainedAt = Date()
        try encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        try manager.moveItem(at: folder, to: target)
        return manifest
    }
    static func pruneDrafts(root: URL, now: Date = Date()) throws {
        let manifests = try list(root: root)
        var bytes: Int64 = 0
        for (index, manifest) in manifests.enumerated() {
            bytes += manifest.files.reduce(0) { $0 + $1.bytes }
            if now.timeIntervalSince(manifest.endedAt) > 24 * 3600 || index >= 10 || bytes > 512 * 1024 * 1024 {
                try remove(id: manifest.id, root: root)
            }
        }
    }
}

struct VisionDiagnosticPose: Codable {
    var capturePTS: Double
    var videoSeconds: Double?
    var receivedUptime: Double
    var width: Double
    var height: Double
    var people: [[PoseTraceJoint]]
    var subjectState: String
    var selectedSubjectIndex: Int?
    var startState: String
    var isCounting: Bool
    var automaticCount: Int
    var countingPhase: String
    var failureReason: String?
    var readingQuality: String
    var angle: Double?
    var latencyMs: Double
    var screenOrientation: VisionScreenOrientation
    var devicePose: VisionDevicePose?
    var cameraGeometry: VisionCameraGeometry?
    var motionStatus: VisionMotionStatus?
    var framing: VisionFraming?
}

struct VisionDiagnosticEvent: Codable {
    var kind: String
    var hostUptime = ProcessInfo.processInfo.systemUptime
    var lastCapturePTS: Double?
    var detail: String?
}
