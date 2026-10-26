import Foundation
import SwiftUI

@MainActor
final class VisionDiagnosticStore: ObservableObject {
    let root: URL
    let draftRoot: URL
    @Published private(set) var recordingID: UUID?
    @Published private(set) var finishing = false
    @Published private(set) var packages: [VisionDiagnosticManifest] = []
    @Published private(set) var drafts: [VisionDiagnosticManifest] = []
    @Published private(set) var working = false
    @Published var error: String?
    @Published private(set) var latestCaptureID: UUID?
    @Published private(set) var latestDisposition: String?
    private var deadline: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var refreshGeneration = 0
    var onLimit: (() -> Void)?
    var isActive: Bool { recordingID != nil }
    var status: String {
        finishing ? "正在整理临时片段" : (isActive ? "临时录像中 · 未保留" :
            (latestDisposition ?? (drafts.isEmpty ? "暂无待核对片段" : "有待核对片段 · 未保留")))
    }
    var reviewCandidate: VisionDiagnosticManifest? {
        guard !isActive, !finishing else { return nil }
        if let latestCaptureID { return drafts.first { $0.id == latestCaptureID } }
        return drafts.first
    }

    init(root: URL = VisionDiagnosticArchive.root, draftRoot: URL? = nil) {
        self.root = root
        self.draftRoot = draftRoot ?? (root == VisionDiagnosticArchive.root ? VisionDiagnosticArchive.draftRoot :
            root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-Drafts"))
        refresh()
    }
    func begin(_ context: VisionDiagnosticContext) -> Bool {
        guard !isActive, !finishing else { return false }
        do {
            let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
            let info = try FileManager.default.attributesOfFileSystem(forPath: path)
            guard (info[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 >= 512 * 1024 * 1024 else {
                throw VisionDiagnosticArchive.error("可用空间不足 512 MiB，未能临时录像；训练可继续。")
            }
            error = nil; recordingID = context.id
            latestCaptureID = context.id; latestDisposition = nil
            deadline = Timer.scheduledTimer(withTimeInterval: context.maximumSeconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLimit?() }
            }
            return true
        } catch {
            latestCaptureID = context.id; latestDisposition = "本次录像不可用"
            self.error = error.localizedDescription; return false
        }
    }
    func markFinishing() {
        guard isActive, !finishing else { return }
        finishing = true
        deadline?.invalidate(); deadline = nil
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Fox diagnostic seal") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.error = "系统结束封存时间；下次打开后检查未完成诊断。"
                self.endBackgroundTask()
            }
        }
    }
    func receive(id: UUID, result: Result<VisionDiagnosticManifest, Error>) {
        guard recordingID == id else { return }
        deadline?.invalidate(); deadline = nil
        recordingID = nil; finishing = false
        endBackgroundTask()
        switch result {
        case .success(let manifest):
            error = manifest.error
            latestDisposition = manifest.video == nil ? "本次诊断待核对 · 无完整视频" : "本次录像待核对 · 未保留"
            if manifest.source == .fixture && ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1" &&
                ProcessInfo.processInfo.environment["FOX_DIAGNOSTIC_SMOKE"] == "1" {
                Task { _ = await retain(manifest) }
            }
        case .failure(let failure):
            latestDisposition = "本次录像不可用"
            error = "诊断未能封存：\(failure.localizedDescription)"
        }
        refresh()
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let root = root, draftRoot = draftRoot
        Task {
            do {
                let (packages, drafts) = try await Task.detached(priority: .utility) {
                    try VisionDiagnosticArchive.pruneDrafts(root: draftRoot)
                    return (try VisionDiagnosticArchive.list(root: root), try VisionDiagnosticArchive.list(root: draftRoot))
                }.value
                guard generation == self.refreshGeneration else { return }
                self.packages = packages
                self.drafts = drafts
            } catch {
                guard generation == self.refreshGeneration else { return }
                self.error = "诊断目录未能读取，文件已保留：\(error.localizedDescription)"
            }
        }
    }
    func remove(_ manifest: VisionDiagnosticManifest) {
        let root = root
        Task {
            do {
                try await Task.detached(priority: .utility) { try VisionDiagnosticArchive.remove(id: manifest.id, root: root) }.value
                if latestCaptureID == manifest.id { latestDisposition = "本次录像已删除 · 记录不受影响" }
                error = nil; refresh()
            }
            catch { self.error = error.localizedDescription }
        }
    }
    func retain(_ manifest: VisionDiagnosticManifest, review: VisionDiagnosticReview? = nil) async -> Bool {
        guard !working else { return false }
        working = true; defer { working = false }
        let root = root, draftRoot = draftRoot
        do {
            _ = try await Task.detached(priority: .utility) {
                try VisionDiagnosticArchive.retain(id: manifest.id, drafts: draftRoot, destination: root, review: review)
            }.value
            if latestCaptureID == manifest.id {
                latestDisposition = manifest.video == nil ? "本次诊断已保留 · 无完整视频" : "本次录像已保留"
            }
            error = nil; refresh(); return true
        } catch { self.error = "未能保留，临时原件未删除：\(error.localizedDescription)"; return false }
    }
    func discard(_ manifest: VisionDiagnosticManifest) async -> Bool {
        guard !working else { return false }
        working = true; defer { working = false }
        let draftRoot = draftRoot
        do {
            try await Task.detached(priority: .utility) { try VisionDiagnosticArchive.remove(id: manifest.id, root: draftRoot) }.value
            if latestCaptureID == manifest.id { latestDisposition = "本次录像已丢弃 · 记录不受影响" }
            error = nil; refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
