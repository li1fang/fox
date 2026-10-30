import SwiftUI
import Combine
import FoxTrainingCore

extension CaptureLabAccess {
    static var current: Self {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return .pad
        case .phone: return .phone
        default: return .other
        }
    }
}

// One stable owner for the native preview and its presentation controller.
@MainActor
final class FreeCaptureRuntime: ObservableObject {
    let backend: FreeCaptureNativeBackend
    let controller: FreeCaptureController
    private var updates: AnyCancellable?
    init(backend: FreeCaptureNativeBackend? = nil) {
        let backend = backend ?? FreeCaptureNativeBackend()
        self.backend = backend
        controller = FreeCaptureController(backend: backend)
        // Keep the parent's mode lock responsive to the child's recording state.
        updates = controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
}

/// The legacy assessment controller remains the owner of exercise evaluation only.
struct CaptureLabView: View {
    @ObservedObject var controller: VisionLabController
    @StateObject private var runtime = FreeCaptureRuntime()
    private var freeCapture: FreeCaptureController { runtime.controller }
    var phoneLandscapeNavigation: AnyView?
    @State private var free = false
    init(controller: VisionLabController, phoneLandscapeNavigation: AnyView? = nil, initialFree: Bool = false) {
        self.controller = controller; self.phoneLandscapeNavigation = phoneLandscapeNavigation
        _free = State(initialValue: initialFree)
    }
    private var modeLocked: Bool {
        freeCapture.selectionLocked || controller.isCounting || controller.isPreparing ||
            controller.diagnosticCapture.isActive || controller.diagnosticCapture.finishing
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("实验方式", selection: $free) {
                Text("动作评测").tag(false); Text("自由采集").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                .disabled(modeLocked).accessibilityIdentifier("capture-lab-mode")
            if free { FreeCaptureView(controller: freeCapture, phoneLandscapeNavigation: phoneLandscapeNavigation,
                previewSession: { runtime.backend.previewSession }) }
            else { VisionLabView(controller: controller, phoneLandscapeNavigation: phoneLandscapeNavigation) }
        }
    }
}

/// A standalone destination: entering capture never constructs or transitions a TrainingStore.
@MainActor
struct CaptureLabDestination: View {
    var body: some View {
        if CaptureLabAccess.current.allowsCapture { PadCaptureLabDestination() }
        else { SavedCaptureDestination() }
    }
}

@MainActor
private struct PadCaptureLabDestination: View {
    @StateObject private var vision = VisionLabController()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CaptureLabView(controller: vision, initialFree: true)
                .navigationTitle("采集与视觉实验").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("capture-lab-close")
                } }
        }
    }
}

@MainActor
struct SavedCaptureDestination: View {
    @StateObject private var controller = FreeCaptureController(backend: SavedCaptureBackend())
    var body: some View { FreeCaptureLibrary(controller: controller, allowsDeletion: false, includesLegacy: true) }
}

struct SavedVisionReports: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reports: [VisionTrial] = []
    @State private var error: String?
    @State private var share: URL?
    static var fileURL: URL {
        let name = ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1" ? "ui-test-vision-trials.json" : "vision-trials.v1.json"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fox").appendingPathComponent(name)
    }
    static func exportCopy(from file: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("fox-vision-reports-\(UUID()).json")
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                if reports.isEmpty { Text("暂无验证报告") }
                ForEach(reports.reversed()) { report in
                    VStack(alignment: .leading) {
                        Text("\(report.resolvedExercise.label) · \(report.arm.label)")
                        Text("自动 \(report.automaticCount) · 确认 \(report.confirmedCount)")
                        Text(report.startedAt.formatted()).font(.caption)
                    }
                }
                Button { do { share = try Self.exportCopy(from: Self.fileURL) } catch { self.error = error.localizedDescription } }
                    label: { Label("导出报告原件副本", systemImage: "square.and.arrow.up") }
                    .disabled(!FileManager.default.fileExists(atPath: Self.fileURL.path))
            }.navigationTitle("验证报告")
                .toolbar { Button("完成") { dismiss() } }
                .task { do { reports = try VisionTrialRepository(fileURL: Self.fileURL).trials } catch { self.error = error.localizedDescription } }
                .sheet(isPresented: Binding(get: { share != nil }, set: { if !$0 { share = nil } })) {
                    if let share { ShareSheet(url: share) }
                }
        }
    }
}

struct SavedDiagnostics: View {
    @Environment(\.dismiss) private var dismiss
    @State private var retained: [VisionDiagnosticManifest] = []
    @State private var drafts: [VisionDiagnosticManifest] = []
    @State private var exporting: VisionDiagnosticManifest?
    @State private var exportRoot = VisionDiagnosticArchive.root
    @State private var error: String?
    nonisolated static func read(root: URL) throws -> [VisionDiagnosticManifest] {
        try VisionDiagnosticArchive.list(root: root, recovering: false)
    }
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                Section("已保留") { entries(retained, root: VisionDiagnosticArchive.root) }
                Section("临时片段 · 不自动清理") { entries(drafts, root: VisionDiagnosticArchive.draftRoot) }
            }.navigationTitle("诊断录像")
                .toolbar { Button("完成") { dismiss() } }
                .task {
                    do {
                        let result = try await Task.detached {
                            (try Self.read(root: VisionDiagnosticArchive.root), try Self.read(root: VisionDiagnosticArchive.draftRoot))
                        }.value
                        retained = result.0; drafts = result.1
                    } catch { self.error = error.localizedDescription }
                }
                .fullScreenCover(item: $exporting) { manifest in
                    FolderExporter(url: exportRoot.appendingPathComponent(manifest.id.uuidString)) { _ in exporting = nil }
                }
        }
    }
    private func entries(_ values: [VisionDiagnosticManifest], root: URL) -> some View {
        ForEach(values) { manifest in
            VStack(alignment: .leading, spacing: 8) {
                Text(manifest.startedAt.formatted())
                Text(manifest.video == nil ? "无完整视频 · 原始诊断保留" : "视频与诊断已保留")
                Button { exportRoot = root; exporting = manifest } label: {
                    Label("导出原件副本", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

// Archive access deliberately has no camera, Vision or Bluetooth dependencies.
@MainActor
final class SavedCaptureBackend: FreeCaptureBackend {
    var onEvent: ((FreeCaptureEvent) -> Void)?
    let root: URL
    init(root: URL = FreeCaptureArchive.root) { self.root = root }
    func refresh() {
        onEvent?(.libraryLoading(true))
        let root = root
        Task {
            let result = await Task.detached { Result { try FreeCaptureArchive.library(root: root) } }.value
            switch result {
            case .success(let library):
                onEvent?(.library(library.packages))
                if !library.issues.isEmpty { onEvent?(.libraryFailure(library.issues.joined(separator: "\n"))) }
            case .failure(let error): onEvent?(.libraryFailure(error.localizedDescription))
            }
            onEvent?(.libraryLoading(false))
        }
    }
    func start(id: UUID, options: FreeCaptureOptions) throws { throw CocoaError(.featureUnsupported) }
    func stop(id: UUID, reason: String) {}
    func remove(id: UUID) {}
}
