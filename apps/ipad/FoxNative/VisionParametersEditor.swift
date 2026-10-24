import FoxTrainingCore
import SwiftUI
import UniformTypeIdentifiers

struct VisionParametersEditor: View {
    @ObservedObject var controller: VisionLabController
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PoseCounterConfiguration.standard
    @State private var runtime = PoseRuntimePolicy.standard
    @State private var error: String?
    @State private var jsonError: String?
    @State private var importing = false
    @State private var editingJSON = false
    @State private var json = ""
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("追踪") {
                    Stepper("获取置信度 \(draft.tracking.acquisitionConfidence.formatted(.number.precision(.fractionLength(2))))",
                            value: $draft.tracking.acquisitionConfidence, in: 0.1...1, step: 0.05).accessibilityIdentifier("pose-acquisition")
                    Stepper("维持置信度 \(draft.tracking.trackingConfidence.formatted(.number.precision(.fractionLength(2))))",
                            value: $draft.tracking.trackingConfidence, in: 0.1...1, step: 0.05)
                    Stepper("容错 \(draft.tracking.graceSeconds.formatted(.number.precision(.fractionLength(2)))) s",
                            value: $draft.tracking.graceSeconds, in: 0...0.5, step: 0.05).accessibilityIdentifier("pose-grace")
                    Toggle("保存关节数值", isOn: $draft.tracking.recordsTrace).accessibilityIdentifier("pose-trace-enabled")
                }
                profileSection("弯举 · 肘角度", profile: $draft.curl)
                profileSection("侧平举 · 上臂外展角", profile: $draft.lateralRaise)
                Section("主体与就位") {
                    Toggle("单一就绪主体可在中心区外启动", isOn: Binding(get: { runtime.acquisitionMode == .singleReadyFallback }, set: {
                        runtime.acquisitionMode = $0 ? .singleReadyFallback : .regionOnly
                    }))
                    Toggle("侧平举使用新鲜对侧躯干参考", isOn: Binding(get: { runtime.lateralTorsoReference == .freshOpposite }, set: {
                        runtime.lateralTorsoReference = $0 ? .freshOpposite : .sameSide
                        if $0 && runtime.maximumTorsoObliquityDegrees == nil { runtime.maximumTorsoObliquityDegrees = 30 }
                    }))
                    if runtime.lateralTorsoReference == .freshOpposite {
                        Stepper("躯干参考倾斜容差 \(Int(runtime.maximumTorsoObliquityDegrees ?? 30))°",
                            value: Binding(get: { runtime.maximumTorsoObliquityDegrees ?? 30 }, set: { runtime.maximumTorsoObliquityDegrees = $0 }), in: 5...30, step: 1)
                    }
                    Stepper("底端容差 \(Int(runtime.endpointToleranceDegrees))°", value: $runtime.endpointToleranceDegrees, in: 0...15, step: 1)
                    Stepper("弯举下放容差 \(Int(runtime.curlReturnToleranceDegrees))°", value: $runtime.curlReturnToleranceDegrees, in: 0...10, step: 1)
                    Stepper("下放确认 \(runtime.returnEndpointDwellSeconds.formatted(.number.precision(.fractionLength(2)))) s",
                        value: $runtime.returnEndpointDwellSeconds, in: 0.1...0.5, step: 0.05)
                    Stepper("放低遮挡 \(runtime.loweredOcclusionSeconds.formatted(.number.precision(.fractionLength(2)))) s",
                        value: $runtime.loweredOcclusionSeconds, in: 0.3...2, step: 0.1)
                    Stepper("主体保留 \(runtime.retentionSeconds.formatted(.number.precision(.fractionLength(2)))) s",
                        value: $runtime.retentionSeconds, in: 0.3...2, step: 0.1)
                    Stepper("倒计时容错 \(runtime.countdownLossTolerance.formatted(.number.precision(.fractionLength(2)))) s",
                        value: $runtime.countdownLossTolerance, in: 0...0.5, step: 0.05)
                }
                Section("参数文件") {
                    Text(draft.name).foregroundStyle(.secondary).accessibilityIdentifier("pose-configuration-name")
                    HStack(spacing: 24) {
                        Button { importing = true } label: { Label("导入", systemImage: "square.and.arrow.down") }
                        Button { exportDraft() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        Button {
                            json = (try? String(data: LocalTrainingRepository.encoder().encode(PoseSessionSettings(configuration: draft, runtimePolicy: runtime)), encoding: .utf8)) ?? ""
                            editingJSON = true
                        } label: { Image(systemName: "curlybraces") }.accessibilityLabel("编辑完整参数")
                    }.buttonStyle(.borderless)
                    Button { draft = .standard; runtime = .standard } label: { Label("恢复默认", systemImage: "arrow.counterclockwise") }
                        .accessibilityIdentifier("pose-reset-defaults")
                }
            }
            .navigationTitle("计数参数")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        do { try controller.applyConfiguration(draft, runtimePolicy: runtime); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(controller.selectionLocked).accessibilityIdentifier("pose-apply-parameters")
                }
            }
            .onAppear { draft = controller.configuration; runtime = controller.runtimePolicy }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try readSettings(Data(contentsOf: url))
                } catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $editingJSON) {
                NavigationStack {
                    TextEditor(text: $json).font(.system(size: 16, design: .monospaced)).padding(16)
                        .accessibilityIdentifier("pose-json-editor")
                        .navigationTitle("完整参数")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { editingJSON = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("读取") {
                                    do { try readSettings(Data(json.utf8)); editingJSON = false }
                                    catch { self.jsonError = error.localizedDescription }
                                }.accessibilityIdentifier("pose-read-json")
                            }
                        }
                        .alert("JSON 无效", isPresented: Binding(get: { jsonError != nil }, set: { if !$0 { jsonError = nil } })) {
                            Button("知道了") { jsonError = nil }
                        } message: { Text(jsonError ?? "") }
                }
            }
            .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
                if let exportURL { ShareSheet(url: exportURL) }
            }
            .alert("参数未应用", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func profileSection(_ title: String, profile: Binding<PoseExerciseProfile>) -> some View {
        Section(title) {
            Stepper("放低 \(Int(profile.wrappedValue.loweredAngleDegrees))°", value: profile.loweredAngleDegrees, in: 0...180, step: 5)
            Stepper("开始上举 \(Int(profile.wrappedValue.departureAngleDegrees))°", value: profile.departureAngleDegrees, in: 0...180, step: 5)
            Stepper("顶峰 \(Int(profile.wrappedValue.peakAngleDegrees))°", value: profile.peakAngleDegrees, in: 0...180, step: 5)
            Stepper("开始下放 \(Int(profile.wrappedValue.returnAngleDegrees))°", value: profile.returnAngleDegrees, in: 0...180, step: 5)
        }
    }

    private func exportDraft() {
        do {
            let settings = PoseSessionSettings(configuration: draft, runtimePolicy: runtime)
            try settings.validate()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fox-pose-session-settings.json")
            try LocalTrainingRepository.encoder().encode(settings).write(to: url, options: .atomic)
            exportURL = url
        } catch { self.error = error.localizedDescription }
    }
    private func readSettings(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["schema"] as? String == "fox.pose_session_settings.v1" {
            let settings = try PoseSessionSettings.decode(data); draft = settings.configuration; runtime = settings.runtimePolicy
        } else { draft = try PoseCounterConfiguration.decode(data) }
    }
}
