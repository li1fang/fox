import PumpCore
import SwiftUI

extension PumpMode {
    var label: String {
        switch self { case .standard: return "标准"; case .constant: return "恒力"; case .eccentric: return "离心"; case .concentric: return "向心" }
    }
}

/// Module: pump.configuration; draft/model inputs, one confirmed request output.
struct PumpConfigurationPanel: View {
    @ObservedObject var model: PumpCaptureRuntime
    let locked: Bool
    @FocusState private var weightFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("模式", selection: $model.mode) {
                ForEach(PumpMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("pump-mode")
            HStack {
                Text("待设定 · 每台")
                TextField("kg", text: $model.kgText).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                    .focused($weightFocused)
                    .frame(width: 100).accessibilityIdentifier("pump-kg")
                Text("kg")
                Spacer()
                Button("最小") { model.kgText = String(format: "%.1f", model.minimum) }.accessibilityIdentifier("pump-minimum")
                Button("最大") { model.kgText = "20.0" }.accessibilityIdentifier("pump-maximum")
            }
            Slider(value: Binding(get: { min(20, max(model.minimum, Double(model.kgText) ?? model.minimum)) },
                set: { model.kgText = String(format: "%.1f", $0) }), in: model.minimum...20, step: 0.1)
                .accessibilityLabel("每台阻力草稿").accessibilityIdentifier("pump-kg-slider")
            Picker("减载", selection: $model.reduction) {
                ForEach([0, 25, 50], id: \.self) { Text("\($0)%").tag($0) }
            }.pickerStyle(.segmented).disabled(model.mode != .eccentric && model.mode != .concentric && model.reduction == 0)
                .accessibilityIdentifier("pump-reduction")
            if let message = model.validationMessage { Text(message).foregroundStyle(.red).accessibilityIdentifier("pump-invalid-draft") }
            if let error = model.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("pump-control-error") }
            HStack {
                Button { model.session?.connectSelected() } label: { Label("连接这一对", systemImage: "link") }
                    .accessibilityIdentifier("pump-connect-pair")
                Spacer()
                Button { weightFocused = false; model.prepareConfirmation() } label: { Label(model.isApplying ? "正在设置" : "应用到两台…", systemImage: "checkmark.circle") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.configuration == nil || model.session?.readiness() != nil || model.session == nil)
                    .accessibilityIdentifier("pump-apply-pair")
            }
            if model.session?.readiness() != nil { Text(model.readiness).font(.callout).foregroundStyle(.secondary) }
            if let result = model.session?.lastResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近一次设置").font(.headline)
                    if let value = model.session?.lastConfiguration { Text("\(value.mode.label) · 每台 \(value.kg.formatted()) kg · 减载 \(value.reduction)%").font(.callout) }
                    ForEach(["A", "B"], id: \.self) { slot in
                        Text("\(slot)：\(resultLabel(result.devices[slot] ?? .notSent))")
                            .accessibilityIdentifier("pump-result-\(slot)")
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("pump-last-result")
            } else { Text("当前阻力未知 · 尚未在 Fox 发送设置").font(.callout).foregroundStyle(.secondary) }
            if locked { Text("录像与封存中 · 仅接收遥测").font(.callout).accessibilityIdentifier("pump-recording-read-only") }
        }
        .disabled(locked || model.isApplying)
        .toolbar { ToolbarItemGroup(placement: .keyboard) {
            Spacer(); Button("完成") { weightFocused = false }.accessibilityIdentifier("pump-keyboard-done")
        } }
        .sheet(item: $model.confirmation) { request in
            NavigationStack {
                Form {
                    Section("本次设置") {
                        Text("\(request.configuration.mode.label) · 每台 \(request.configuration.kg.formatted()) kg")
                            .accessibilityIdentifier("pump-confirm-parameters")
                        Text("减载 \(request.configuration.reduction)%")
                        ForEach(["A", "B"], id: \.self) { slot in
                            Text("\(slot)：\(model.session?.devices.first(where: { $0.id.uuidString == request.devices[slot] })?.name ?? slot)")
                        }
                    }
                    if model.session?.requiresRecovery == true { Text("上一轮存在部分或未知结果。本次是新的设置，不会补发上一轮。") }
                    Text("确认器材已准备好后再设置。写入回执不是实测阻力；断开蓝牙不代表卸力。")
                    Button("确认设置两台各一次") { Task { await model.applyConfirmed(request) } }
                        .accessibilityIdentifier("pump-confirm-send")
                }.navigationTitle("确认这一对与参数").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { model.confirmation = nil } } }
            }.interactiveDismissDisabled(model.isApplying)
        }
    }
    private func resultLabel(_ value: PumpLegResult) -> String {
        switch value {
        case .notSent: return "未发送"
        case .gattAckUnverified: return "写入有回执 · 物理效果待核对"
        case .responseUnverified: return "设备有响应 · 物理效果待核对"
        case .unknown: return "结果未知 · 未自动重发"
        }
    }
}
