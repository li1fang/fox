import AVFoundation
import AVKit
import SwiftUI

struct FreeCaptureView: View {
    @ObservedObject var controller: FreeCaptureController
    var phoneLandscapeNavigation: AnyView? = nil
    var previewSession: () -> AVCaptureSession? = { nil }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingLibrary = false
    @State private var choosingPump = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("不指定动作，直接录像。姿态分析或 PUMP 不可用时，录像仍会继续。")
                    .font(.callout).foregroundStyle(.secondary)
                Group {
                    Picker("相机", selection: Binding(get: { controller.options.frontCamera }, set: { controller.changeCamera(front: $0) })) {
                        Text("前置").tag(true); Text("后置").tag(false)
                    }.pickerStyle(.segmented).accessibilityIdentifier("free-capture-camera")
                    Picker("姿态分析", selection: Binding(get: { controller.options.analysis }, set: { controller.changeAnalysis($0) })) {
                        ForEach(FreeCaptureAnalysis.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("free-capture-analysis")
                    Toggle("PUMP 只读遥测", isOn: Binding(get: { controller.options.pumpEnabled }, set: { controller.changePump(enabled: $0) }))
                        .accessibilityIdentifier("free-capture-pump")
                }.disabled(controller.selectionLocked)
                if controller.options.pumpEnabled {
                    Button { controller.scanPump(); choosingPump = true } label: { Label("选择 PUMP", systemImage: "antenna.radiowaves.left.and.right") }
                        .disabled(controller.selectionLocked).accessibilityIdentifier("free-capture-select-pump")
                    ForEach(controller.pumpDevices.filter { $0.alias != nil }) { device in
                        HStack {
                            Text("\(device.alias ?? "PUMP")：\(device.state)").font(.callout)
                                .accessibilityIdentifier("free-capture-\(device.alias ?? "pump")-status")
                            if controller.phase == .recording, device.canReconnect {
                                Button("重新连接") { controller.reconnectPump(device.id) }
                                    .accessibilityIdentifier("free-capture-reconnect-\(device.alias ?? "pump")")
                            }
                        }
                    }
                }
                if let session = previewSession() {
                    FreeCapturePreview(session: session, mirrored: controller.options.frontCamera)
                        .frame(height: verticalSizeClass == .compact ? 180 : 300).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(controller.status).font(.title3.bold()).accessibilityIdentifier("free-capture-status")
                if let reason = controller.latest?.stopDescription { Text(reason).font(.callout).accessibilityIdentifier("free-capture-stop-reason") }
                Text(controller.sourceLabel).font(.caption).accessibilityIdentifier("free-capture-source")
                Text(controller.cameraStatus).font(.callout).accessibilityIdentifier("free-capture-camera-status")
                if let began = controller.recordingSince {
                    Text(began, style: .timer).monospacedDigit().accessibilityLabel("录制时间")
                }
                Text(controller.frameStatus)
                    .accessibilityIdentifier("free-capture-frame-status")
                Text("姿态：\(controller.analysisStatus)").accessibilityIdentifier("free-capture-analysis-status")
                Text(controller.sensorStatus).accessibilityIdentifier("free-capture-sensor-status")
                Text("动作与次数：\(controller.evaluationStatus)").accessibilityIdentifier("free-capture-not-evaluated")
                if let error = controller.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("free-capture-error") }
                Text("无声录像，单段最多 5 分钟。停止后保存实验原件，仅手动删除；不自动上传。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { controller.refresh(); showingLibrary = true } label: { Label("已保存实验", systemImage: "folder") }
                    .disabled(controller.selectionLocked).accessibilityIdentifier("free-capture-library")
            }.padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if controller.phase == .starting || controller.phase == .recording {
                    FoxCommand(title: "停止并保存", icon: "stop.circle.fill", prominent: true) { controller.stop(reason: "userStopped") }
                        .accessibilityIdentifier("free-capture-stop")
                } else {
                    FoxCommand(title: controller.phase == .finishing ? "正在封存" : "开始录制", icon: "record.circle", prominent: true) { controller.start() }
                        .disabled(controller.phase == .finishing).accessibilityIdentifier("free-capture-start")
                }
            }.padding().background(.bar)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if UIDevice.current.userInterfaceIdiom == .phone,
               FoxAdaptiveLayout.sideBySide(horizontal: horizontalSizeClass, vertical: verticalSizeClass),
               let navigation = phoneLandscapeNavigation { navigation }
        }
        .onAppear { controller.refresh() }
        .onDisappear { controller.stop(reason: "viewClosed"); controller.stopPumpScan() }
        // Permission prompts can make the scene inactive; actual background ends the clip.
        // AV session interruptions are separately handled by the camera adapter.
        .onChange(of: scenePhase) { if $0 == .background { controller.stop(reason: "background") } }
        .sheet(isPresented: $showingLibrary) { FreeCaptureLibrary(controller: controller) }
        .sheet(isPresented: $choosingPump, onDismiss: { controller.stopPumpScan() }) { FreeCapturePumpPicker(controller: controller) }
    }
}

private struct FreeCapturePumpPicker: View {
    @ObservedObject var controller: FreeCaptureController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text(controller.pumpDiscoveryStatus).accessibilityIdentifier("free-capture-pump-discovery")
                Text("最多选择两台。pump-A 与 pump-B 是采集别名，不代表左右手；遥测单位尚未核实。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(controller.pumpDevices) { device in
                    Button { controller.selectPump(device.id) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.alias ?? "未选择").font(.caption)
                            }
                            Spacer()
                            if device.alias != nil { Image(systemName: "checkmark.circle.fill") }
                        }
                    }.accessibilityIdentifier("free-capture-pump-device-\(device.id.uuidString)")
                }
                Button("重新扫描") { controller.scanPump() }
                    .accessibilityIdentifier("free-capture-pump-rescan")
            }.navigationTitle("选择 PUMP")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { controller.stopPumpScan(); dismiss() } } }
        }
    }
}

struct FreeCapturePreview: UIViewRepresentable {
    var session: AVCaptureSession
    var mirrored: Bool
    func makeUIView(context: Context) -> Surface {
        let view = Surface(); view.preview.session = session; view.preview.videoGravity = .resizeAspect
        view.backgroundColor = .black; view.accessibilityIdentifier = "free-capture-preview"
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {
        if view.preview.session !== session { view.preview.session = session }
        if let connection = view.preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

struct FreeCaptureLibrary: View {
    @ObservedObject var controller: FreeCaptureController
    var allowsDeletion = true
    var includesLegacy = false
    @State private var showingReports = false
    @State private var showingDiagnostics = false
    @Environment(\.dismiss) private var dismiss
    @State private var viewing: FreeCapturePackageSummary?
    @State private var exporting: FreeCapturePackageSummary?
    @State private var deleting: FreeCapturePackageSummary?
    var body: some View {
        NavigationStack {
            List {
                if controller.libraryLoading { ProgressView("正在核对实验原件…") }
                if let error = controller.error { Text(error).foregroundStyle(.red) }
                if let status = controller.exportStatus { Text(status).accessibilityIdentifier("free-capture-export-status") }
                if controller.packages.isEmpty && !controller.libraryLoading { Text("暂无已保存实验").accessibilityIdentifier("free-capture-empty") }
                ForEach(controller.packages) { package in
                    VStack(alignment: .leading, spacing: 10) {
                        Button { viewing = package } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(package.recordedAt.formatted(date: .abbreviated, time: .standard))
                                Text(package.videoStatus)
                                Text(package.frameSummary).font(.caption)
                                if let reason = package.stopDescription { Text(reason).font(.caption) }
                                if package.synthetic { Text("合成测试样本 · 非真实相机").font(.caption) }
                            }
                        }.buttonStyle(.borderless).accessibilityIdentifier("free-capture-package-\(package.id.uuidString)")
                        HStack {
                            Button { exporting = package } label: { Label("导出副本", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.borderless).accessibilityIdentifier("free-capture-export-\(package.id.uuidString)")
                            Spacer()
                            if allowsDeletion { Button(role: .destructive) { deleting = package } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                                .buttonStyle(.borderless).accessibilityLabel("删除这份实验原件")
                            }
                        }
                    }.padding(.vertical, 8)
                }
            }.disabled(controller.libraryLoading).navigationTitle("已保存实验")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $viewing) { FreeCapturePlayback(package: $0) }
                .safeAreaInset(edge: .bottom) {
                    if includesLegacy {
                        HStack {
                            Button("验证报告") { showingReports = true }
                            Spacer()
                            Button("诊断录像") { showingDiagnostics = true }
                        }.padding().background(.bar)
                    }
                }
                .sheet(isPresented: $showingReports) { SavedVisionReports() }
                .sheet(isPresented: $showingDiagnostics) { SavedDiagnostics() }
                .fullScreenCover(item: $exporting) { package in
                    if let url = controller.exportURL(for: package) {
                        FolderExporter(url: url) { success in controller.exportFinished(success: success); exporting = nil }
                    }
                }
                .confirmationDialog("删除这份本机实验原件？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("删除", role: .destructive) { if let deleting { controller.remove(deleting) }; deleting = nil }
                    Button("取消", role: .cancel) { deleting = nil }
                } message: { Text("这会删除该实验的视频与关联资料，不更改训练记录。") }
        }
    }
}

private struct FreeCapturePlayback: View {
    var package: FreeCapturePackageSummary
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let player { VideoPlayer(player: player).frame(minHeight: 220) }
                Text(package.videoAvailable ? "实验原片 · 动作与次数未评测" : "无完整视频，故障资料仍保留")
                    .accessibilityIdentifier("free-capture-playback-status")
            }.padding().navigationTitle("查看实验")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear { if package.videoAvailable { player = AVPlayer(url: package.folder.appendingPathComponent("video.mp4")) } }
                .onDisappear { player?.pause(); player = nil }
        }
    }
}
