import AVKit
import FoxTrainingCore
import SwiftUI

struct VisionRecordingDisposition: View {
    @ObservedObject var capture: VisionDiagnosticStore
    var body: some View {
        Text(capture.status).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("vision-recording-disposition")
    }
}

struct VisionDiagnosticControls: View {
    @ObservedObject private var capture: VisionDiagnosticStore
    @State private var browsing = false
    @State private var reviewing: VisionDiagnosticManifest?
    private let identifierPrefix: String
    init(controller: VisionLabController, identifierPrefix: String = "diagnostic") {
        capture = controller.diagnosticCapture; self.identifierPrefix = identifierPrefix
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(capture.status, systemImage: capture.isActive ? "record.circle" : "video")
                    .font(.system(size: 17)).foregroundStyle(capture.isActive ? FoxStyle.coral : .secondary)
                    .accessibilityIdentifier("\(identifierPrefix)-status")
                Spacer()
                Button { capture.refresh(); browsing = true } label: { Image(systemName: "folder").frame(width: 44, height: 44) }
                    .buttonStyle(.borderless)
                    .disabled(capture.isActive || capture.finishing)
                    .accessibilityLabel("诊断文件").help("诊断文件").accessibilityIdentifier("\(identifierPrefix)-library")
            }
            if let latest = capture.reviewCandidate {
                Button { reviewing = latest } label: {
                    Label(capture.latestCaptureID == latest.id ? "核对本次录像" : "核对待处理录像", systemImage: "play.rectangle")
                }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("\(identifierPrefix)-review-latest")
            }
            if let error = capture.error {
                Text(error).font(.system(size: 16)).foregroundStyle(FoxStyle.coral).accessibilityIdentifier("diagnostic-error")
            }
        }.accessibilityElement(children: .contain)
        .sheet(isPresented: $browsing) { VisionDiagnosticLibrary(capture: capture) }
        .sheet(item: $reviewing) { DiagnosticReview(capture: capture, manifest: $0) }
    }
}

struct DiagnosticReview: View {
    @ObservedObject var capture: VisionDiagnosticStore
    let manifest: VisionDiagnosticManifest
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var reference = ""
    @State private var information = ""
    @State private var softwareIssue = ""
    @State private var trainingFeeling = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(manifest.source == .fixture ? "测试样本 · 非真实相机" : "本机相机").foregroundStyle(.secondary)
                    if manifest.video != nil {
                        VideoPlayer(player: player).frame(height: 280).accessibilityIdentifier("diagnostic-video-player")
                    } else { Text("无完整视频 · 本次故障诊断仍可保留") }
                    Text(manifest.automaticCount.map { "自动观测 \($0) 次 · 尚非人工确认" } ?? "自动观测次数未记录")
                    Text("临时片段 · 尚未保留").foregroundStyle(FoxStyle.coral).accessibilityIdentifier("diagnostic-pending-retention")
                    TextField("人工参考次数（可留空）", text: $reference).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("diagnostic-reference-count")
                    TrialReviewFields(information: $information, softwareIssue: $softwareIssue, trainingFeeling: $trainingFeeling)
                    if let error = capture.error { Text(error).foregroundStyle(FoxStyle.coral) }
                    Button {
                        player?.pause(); player = nil
                        Task {
                            do {
                                let now = Date()
                                guard reference.isEmpty || Int(reference).map({ (0...10000).contains($0) }) == true else {
                                    throw VisionDiagnosticArchive.error("人工参考次数应为非负整数，也可以留空。")
                                }
                                let review = VisionDiagnosticReview(diagnosticID: manifest.id, reviewedAt: now, referenceCount: Int(reference),
                                    review: try TrialReview.make(information: information, softwareIssue: softwareIssue, trainingFeeling: trainingFeeling, at: now))
                                if await capture.retain(manifest, review: review) { dismiss() }
                                else { loadPlayer() }
                            } catch { capture.error = error.localizedDescription; loadPlayer() }
                        }
                    } label: { Label("保留诊断", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("diagnostic-keep")
                    Button(role: .destructive) {
                        player?.pause(); player = nil
                        Task { if await capture.discard(manifest) { dismiss() } else { loadPlayer() } }
                    } label: { Label("不保留", systemImage: "trash") }
                        .accessibilityIdentifier("diagnostic-discard")
                }.padding(24).frame(maxWidth: 800).frame(maxWidth: .infinity)
            }.navigationTitle("核对本次录像").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后") { dismiss() } } }
                .disabled(capture.working).interactiveDismissDisabled(capture.working)
                .onAppear { loadPlayer() }.onDisappear { player?.pause(); player = nil }
        }
    }
    private func loadPlayer() {
        guard manifest.video != nil else { return }
        player = AVPlayer(url: capture.draftRoot.appendingPathComponent(manifest.id.uuidString).appendingPathComponent("video.mp4"))
    }
}

struct VisionDiagnosticLibrary: View {
    @ObservedObject var capture: VisionDiagnosticStore
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: VisionDiagnosticManifest?
    @State private var deleting: VisionDiagnosticManifest?
    @State private var reviewing: VisionDiagnosticManifest?
    @State private var status: String?
    @State private var showingRetained = true
    var body: some View {
        NavigationStack {
            List {
                if capture.finishing { ProgressView("正在整理临时片段…").accessibilityIdentifier("diagnostic-finalizing") }
                if let error = capture.error { Text(error).foregroundStyle(FoxStyle.coral) }
                if let status { Text(status).accessibilityIdentifier("diagnostic-export-status") }
                DiagnosticLibraryFilter(showingRetained: $showingRetained,
                    retainedCount: capture.packages.count, pendingCount: capture.drafts.count)
                    .frame(height: 36)
                if !showingRetained {
                Section("待核对 · 临时") {
                    if capture.drafts.isEmpty { Text("暂无待核对片段") }
                    ForEach(capture.drafts) { manifest in
                        Button { reviewing = manifest } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(manifest.startedAt.formatted(date: .abbreviated, time: .standard))
                                Text("未保留 · 核对录像").foregroundStyle(FoxStyle.coral)
                            }
                        }.accessibilityIdentifier("diagnostic-draft-\(manifest.id.uuidString)")
                    }
                }
                }
                if showingRetained {
                Section("已保留") {
                    if capture.packages.isEmpty { Text("暂无已保留诊断").accessibilityIdentifier("diagnostic-empty") }
                    ForEach(capture.packages) { manifest in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(manifest.startedAt.formatted(date: .abbreviated, time: .standard)).font(.headline)
                            Text(manifest.source == .fixture ? "测试样本 · 非真实相机" : "本机相机")
                            Text(manifest.video == nil ? "无完整视频 · 诊断已保留" : "视频与诊断已保留")
                                .accessibilityIdentifier("diagnostic-package-status")
                            HStack {
                                Button { exporting = manifest } label: { Label("导出到文件", systemImage: "square.and.arrow.up") }
                                    .buttonStyle(.borderless).accessibilityIdentifier("diagnostic-export-\(manifest.id.uuidString)")
                                Spacer()
                                Button(role: .destructive) { deleting = manifest } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                                    .buttonStyle(.borderless).accessibilityLabel("删除这份诊断")
                            }
                        }.padding(.vertical, 8)
                    }
                }
                }
            }.navigationTitle("诊断文件")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear { capture.refresh() }
                .sheet(item: $reviewing) { DiagnosticReview(capture: capture, manifest: $0) }
                .fullScreenCover(item: $exporting) { manifest in
                    FolderExporter(url: capture.root.appendingPathComponent(manifest.id.uuidString)) { success in
                        status = success ? "已导出副本，本机原件保留。" : "已关闭导出面板，本机原件保留。"
                        exporting = nil
                    }
                }
                .confirmationDialog("删除本机这份诊断？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("删除", role: .destructive) { if let deleting { capture.remove(deleting) }; deleting = nil }
                    Button("取消", role: .cancel) { deleting = nil }
                } message: { Text("视频与同步诊断将一起删除，不影响训练记录。") }
        }
    }
}

// Keep segment identity stable while live-camera parent views and archive counts refresh.
// The SwiftUI Picker intermittently delivered the old selection for a tap on the other segment.
private struct DiagnosticLibraryFilter: UIViewRepresentable {
    @Binding var showingRetained: Bool
    let retainedCount: Int
    let pendingCount: Int

    func makeCoordinator() -> Coordinator { Coordinator(selection: $showingRetained) }
    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: ["", ""])
        control.accessibilityIdentifier = "diagnostic-filter"
        control.accessibilityLabel = "诊断文件"
        control.addTarget(context.coordinator, action: #selector(Coordinator.select(_:)), for: .valueChanged)
        return control
    }
    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $showingRetained
        let titles = ["已保留 \(retainedCount)", "待核对 \(pendingCount)"]
        for (index, title) in titles.enumerated() where control.titleForSegment(at: index) != title {
            control.setTitle(title, forSegmentAt: index)
        }
        let index = showingRetained ? 0 : 1
        if control.selectedSegmentIndex != index { control.selectedSegmentIndex = index }
    }
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Bool>
        init(selection: Binding<Bool>) { self.selection = selection }
        @objc func select(_ control: UISegmentedControl) {
            guard (0...1).contains(control.selectedSegmentIndex) else { return }
            selection.wrappedValue = control.selectedSegmentIndex == 0
        }
    }
}
