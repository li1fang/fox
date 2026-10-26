import FoxTrainingCore
import SwiftUI

struct VisionLabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var controller: VisionLabController
    @StateObject private var guidance: GuidanceSession
    var phoneLandscapeNavigation: AnyView? = nil
    @State private var reviewing = false
    @State private var choosingBodyView = false
    @State private var cameraViewVisible = false
    @State private var exportURL: URL?
    @State private var sharing = false
    @State private var editingParameters = false
    @State private var showingPhoneOptions = false
    @State private var parametersAfterOptions = false
    @State private var shareAfterOptions = false
    @State private var showingGuidanceOptions = false
    private var sideBySide: Bool { FoxAdaptiveLayout.sideBySide(horizontal: horizontalSizeClass, vertical: verticalSizeClass) }

    init(controller: VisionLabController, phoneLandscapeNavigation: AnyView? = nil) {
        self.controller = controller; self.phoneLandscapeNavigation = phoneLandscapeNavigation
        _guidance = StateObject(wrappedValue: GuidanceSession(vision: controller))
    }

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .phone { phoneBody }
            else { tabletBody }
        }
        .onAppear { cameraViewVisible = true; controller.startCamera(); guidance.start() }
        .onDisappear { cameraViewVisible = false; choosingBodyView = false; guidance.stop(); controller.stopCamera() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { resumePreviewIfNeeded(); guidance.start() }
            else { guidance.stop(); controller.finishDiagnostic(reason: "background"); controller.stopCamera() }
        }
        .onChange(of: choosingBodyView) { selecting in if !selecting { resumePreviewIfNeeded() } }
        .sheet(isPresented: $reviewing, onDismiss: { resumePreviewIfNeeded() }) {
            VisionReportEditor(controller: controller)
        }
        .sheet(isPresented: $sharing, onDismiss: { resumePreviewIfNeeded() }) { if let exportURL { ShareSheet(url: exportURL) } }
        .sheet(isPresented: $showingPhoneOptions, onDismiss: {
            if parametersAfterOptions {
                parametersAfterOptions = false; controller.stopCamera(); editingParameters = true
            } else if shareAfterOptions {
                shareAfterOptions = false; sharing = true
            } else { resumePreviewIfNeeded() }
        }) { phoneOptions }
        .sheet(isPresented: $editingParameters, onDismiss: { resumePreviewIfNeeded() }) {
            VisionParametersEditor(controller: controller)
        }
        .sheet(isPresented: $showingGuidanceOptions) {
            NavigationStack {
                Form { GuidanceControls(session: guidance) }
                    .navigationTitle("视听引导").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showingGuidanceOptions = false }.accessibilityIdentifier("guidance-options-done")
                    } }
            }
        }
    }

    private var phoneBody: some View {
        let landscape = sideBySide
        let actionsLayout = landscape ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return PhoneCameraLayout(landscape: landscape, spacing: landscape ? 12 : 8) {
            VStack(spacing: 8) {
                if landscape { phoneLandscapeNavigation }
                if landscape && typeSize.isAccessibilitySize { ScrollView { phoneSidebarInformation } }
                else { phoneSidebarInformation }
            }
            PhoneCameraStage(controller: controller, guidance: guidance)
            actionsLayout { countingActions }
        }
        .padding(.horizontal, 12).padding(.vertical, landscape ? 12 : 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: landscape)
    }

    private var phoneSidebarInformation: some View {
        VStack(spacing: 8) {
            phoneStatus
            taskInformation
            if sideBySide { phoneQuickSelections }
            phoneError
        }
    }

    private var phoneQuickSelections: some View {
        VStack(spacing: 8) {
            Picker("动作", selection: Binding(get: { controller.exercise }, set: { controller.changeExercise($0) })) {
                ForEach(VisionExercise.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).disabled(controller.selectionLocked).accessibilityIdentifier("vision-quick-exercise")
            Picker("追踪手臂", selection: Binding(get: { controller.arm }, set: { controller.changeArm($0) })) {
                ForEach(ArmSide.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).disabled(controller.selectionLocked).accessibilityIdentifier("vision-quick-arm")
        }
    }

    private var phoneStatus: some View {
        HStack(spacing: 12) {
                Text("\(controller.confirmedCount)").font(.system(size: 36, weight: .bold)).monospacedDigit()
                    .accessibilityIdentifier("vision-count")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(controller.exercise.label) · \(controller.arm.label)").font(.subheadline.weight(.semibold))
                    Text(controller.qualityLabel).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vision-quality")
                }.frame(maxWidth: .infinity, alignment: .leading)
                GuidanceMuteButton(session: guidance)
                Button {
                    if !controller.selectionLocked { controller.stopCamera() }
                    showingPhoneOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.title2).frame(width: 44, height: 44)
                }.accessibilityLabel("视觉设置与报告").accessibilityIdentifier("vision-options").help("视觉设置与报告")
            }
    }

    @ViewBuilder private var phoneError: some View {
            if let error = controller.errorMessage {
                Text(error).font(.callout).foregroundStyle(FoxStyle.coral).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("vision-error")
            }
    }

    private var phoneOptions: some View {
        NavigationStack {
            Form {
                Section("动作与机位") {
                    Picker("动作", selection: Binding(get: { controller.exercise }, set: { controller.changeExercise($0) })) {
                        ForEach(VisionExercise.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).disabled(controller.selectionLocked).accessibilityIdentifier("vision-exercise")
                    Picker("追踪手臂", selection: Binding(get: { controller.arm }, set: { controller.changeArm($0) })) {
                        ForEach(ArmSide.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).disabled(controller.selectionLocked).accessibilityIdentifier("vision-arm")
                    Picker("相机", selection: Binding(get: { controller.frontCamera }, set: { controller.changeCamera($0, restartPreview: false) })) {
                        Text("前置").tag(true); Text("后置").tag(false)
                    }.pickerStyle(.segmented).disabled(controller.selectionLocked).accessibilityIdentifier("vision-camera")
                    Picker("人体朝向", selection: Binding(get: { controller.declaredBodyView }, set: { controller.changeBodyView($0) })) {
                        ForEach(VisionBodyView.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.navigationLink).disabled(controller.selectionLocked).accessibilityIdentifier("vision-body-view")
                    Button {
                        parametersAfterOptions = true; showingPhoneOptions = false
                    } label: { Label("计数参数", systemImage: "slider.horizontal.3") }
                        .disabled(controller.selectionLocked).accessibilityIdentifier("vision-parameters")
                    Text(controller.exercise.guidance).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("vision-guidance")
                }
                Section("视听引导") { GuidanceControls(session: guidance) }
                Section("次数核对") {
                    HStack {
                        Text("自动 \(controller.automaticCount) · 人工 \(controller.manualAdjustment >= 0 ? "+" : "")\(controller.manualAdjustment)")
                            .accessibilityIdentifier("vision-original-count")
                        Spacer()
                        Button { controller.correct(by: -1) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).disabled(!controller.trialActive || controller.confirmedCount == 0).accessibilityLabel("次数减一")
                        Button { controller.correct(by: 1) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).disabled(!controller.trialActive).accessibilityLabel("次数加一")
                    }
                    LabeledContent(controller.exercise.angleLabel, value: controller.reading.angle.map { "\(Int($0.rounded()))°" } ?? "未测得")
                    if let rep = controller.repetitions.last {
                        HStack {
                            phaseMetric(controller.exercise == .latPulldown ? "下拉" : "上举", value: rep.liftSeconds)
                            Spacer()
                            if controller.exercise == .latPulldown {
                                phaseMetric("前次返回", value: rep.precedingReturn?.measurement.durationSeconds)
                            } else {
                                phaseMetric("停留", value: rep.holdSeconds); Spacer(); phaseMetric("下放", value: rep.lowerSeconds)
                            }
                        }
                    }
                }
                Section("诊断与最近报告") { diagnosticDetails }
            }.navigationTitle("视觉设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingPhoneOptions = false }.accessibilityIdentifier("vision-options-done") } }
        }
    }

    private var tabletBody: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { tabletSelections; tabletTools }
                VStack(spacing: 8) { tabletSelections; tabletTools }
            }
            Text(controller.exercise.guidance).font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("vision-guidance")
            phoneError
            GeometryReader { geometry in
                let wide = geometry.size.width >= 850
                let actionsLayout = wide ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
                // All orientations retain the same preview and pin actions outside scrolling diagnostics.
                PhoneCameraLayout(landscape: wide, spacing: 16, cameraLeading: true) {
                    ScrollView { controls }
                        .frame(maxHeight: wide ? .infinity : (typeSize.isAccessibilitySize ? 280 : 210))
                    cameraSurface
                    actionsLayout { countingActions }
                }
            }
        }.padding(20)
    }

    private var tabletSelections: some View {
            HStack(spacing: 16) {
                Picker("动作", selection: Binding(get: { controller.exercise }, set: { controller.changeExercise($0) })) {
                    ForEach(VisionExercise.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).frame(width: 280).disabled(controller.selectionLocked)
                    .accessibilityIdentifier("vision-exercise")
                Picker("追踪手臂", selection: Binding(get: { controller.arm }, set: { controller.changeArm($0) })) {
                    ForEach(ArmSide.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).frame(width: 160).disabled(controller.selectionLocked)
                    .accessibilityIdentifier("vision-arm")
            }
    }

    private var tabletTools: some View {
            HStack(spacing: 12) {
                Button { showingGuidanceOptions = true } label: {
                    Image(systemName: "waveform").font(.title2).frame(width: 44, height: 44)
                }.accessibilityLabel("视听引导设置").help("视听引导设置").accessibilityIdentifier("guidance-options")
                Button {
                    controller.stopCamera(); editingParameters = true
                } label: { Image(systemName: "slider.horizontal.3").font(.title2).frame(width: 44, height: 44) }
                    .help("计数参数").accessibilityLabel("计数参数").accessibilityIdentifier("vision-parameters")
                    .disabled(controller.selectionLocked)
                Text(controller.source == .fixture ? "测试数据" : "本机相机").font(.system(size: 17)).foregroundStyle(.secondary)
                Picker("相机", selection: Binding(get: { controller.frontCamera }, set: { controller.changeCamera($0) })) {
                    Text("前置").tag(true); Text("后置").tag(false)
                }.pickerStyle(.segmented).frame(width: 150).disabled(controller.selectionLocked)
            }
    }

    private var cameraSurface: some View {
        ZStack {
            PosePreview(controller: controller)
            if let frame = controller.latest?.frame {
                GuidanceCameraOverlay(output: guidance.output, imageSize: CGSize(width: frame.width, height: frame.height), active: controller.isCounting)
            }
            if case .countdown(let seconds) = controller.startState {
                Text("\(seconds)").font(.system(size: 110, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white).padding(24).background(.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("vision-countdown")
            }
            if controller.cameraState != .running {
                VStack(spacing: 20) {
                    Image(systemName: "camera").font(.system(size: 44))
                    Text(controller.cameraState.label).font(.system(size: 23, weight: .semibold)).multilineTextAlignment(.center)
                    if controller.cameraState == .denied || controller.cameraState == .restricted {
                        Button { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } label: {
                            Label("打开设置", systemImage: "gearshape").font(.system(size: 20, weight: .semibold))
                        }.accessibilityIdentifier("vision-open-settings")
                    } else if controller.cameraState != .requestingPermission && controller.cameraState != .starting {
                        Button { controller.retryCamera() } label: { Label("重试相机", systemImage: "arrow.clockwise") }.font(.system(size: 20))
                    }
                }.foregroundStyle(.white).padding(28)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) { GuidanceMuteButton(session: guidance).padding(12) }
        .overlay(alignment: .topLeading) {
            Text(controller.qualityLabel).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                .padding(12).background(.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 4)).padding(12)
                .accessibilityIdentifier("vision-quality")
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 20) {
                Text("\(controller.latest?.frame.people.count ?? 0) 人")
                Text("\(controller.reading.visiblePoints) 个关键点")
                Text("置信度 \(Int(controller.reading.confidence * 100))%")
            }.font(.system(size: 17)).monospacedDigit().foregroundStyle(.white)
                .padding(12).background(.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 4)).padding(12)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            taskInformation
            HStack {
                Text(controller.savedReceipt == nil ? "待核对次数" : "最近已保存").font(.system(size: 20)).foregroundStyle(.secondary)
                Spacer()
                Text(controller.arm.label).font(.system(size: 18))
            }
            HStack(alignment: .center) {
                Text("\(controller.confirmedCount)").font(.system(size: 64, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.5)
                    .accessibilityIdentifier("vision-count")
                Spacer()
                VStack(spacing: 16) {
                    Button { controller.correct(by: 1) } label: { Image(systemName: "plus").font(.title2).frame(width: 48, height: 48) }
                        .disabled(!controller.trialActive).help("次数加一").accessibilityLabel("次数加一")
                    Button { controller.correct(by: -1) } label: { Image(systemName: "minus").font(.title2).frame(width: 48, height: 48) }
                        .disabled(!controller.trialActive || controller.confirmedCount == 0).help("次数减一").accessibilityLabel("次数减一")
                }
            }
            Text("自动 \(controller.automaticCount) · 人工 \(controller.manualAdjustment >= 0 ? "+" : "")\(controller.manualAdjustment)")
                .font(.system(size: 19)).foregroundStyle(.secondary).accessibilityIdentifier("vision-original-count")
            HStack {
                Text(controller.exercise.angleLabel).foregroundStyle(.secondary)
                Spacer()
                Text(controller.reading.angle.map { "\(Int($0.rounded()))°" } ?? "未测得").monospacedDigit()
            }.font(.system(size: 22))
            if let rep = controller.repetitions.last {
                HStack(spacing: 20) {
                    phaseMetric(controller.exercise == .latPulldown ? "下拉段" : "上举段", value: rep.liftSeconds)
                    if controller.exercise == .latPulldown {
                        phaseMetric("前次返回", value: rep.precedingReturn?.measurement.durationSeconds)
                    } else {
                        phaseMetric("顶部段", value: rep.holdSeconds)
                        phaseMetric("下放段", value: rep.lowerSeconds)
                    }
                }
                Text("上次已记录的区间 · 非实时节奏").font(.system(size: 16)).foregroundStyle(.secondary)
                if (rep.trackingGapSeconds ?? 0) > 0 {
                    Text("节奏约略 · 追踪缺口 \((rep.trackingGapSeconds ?? 0).formatted(.number.precision(.fractionLength(1)))) s")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("人体朝向").foregroundStyle(.secondary)
                Spacer()
                Button {
                    controller.stopCamera(); choosingBodyView = true
                } label: {
                    HStack(spacing: 6) {
                        Text(controller.declaredBodyView.label)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }.disabled(controller.selectionLocked).accessibilityIdentifier("vision-body-view")
                    .popover(isPresented: $choosingBodyView) {
                        VStack(spacing: 0) {
                            ForEach(VisionBodyView.allCases, id: \.self) { view in
                                Button {
                                    controller.changeBodyView(view); choosingBodyView = false
                                } label: {
                                    HStack {
                                        Text(view.label)
                                        Spacer()
                                        if controller.declaredBodyView == view { Image(systemName: "checkmark") }
                                    }.padding(.horizontal, 18).frame(height: 48).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("vision-body-view-\(view.rawValue)")
                            }
                        }.font(.system(size: 20)).padding(.vertical, 8).frame(width: 240)
                    }
            }
            Divider()
            diagnosticDetails
        }.font(.system(size: 18))
    }

    @ViewBuilder private var taskInformation: some View {
        if let receipt = controller.savedReceipt {
            Text(receipt).font(.callout.weight(.semibold)).foregroundStyle(FoxStyle.green)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("vision-saved-receipt")
            VisionRecordingDisposition(capture: controller.diagnosticCapture)
        } else {
            VisionTaskDetail(message: controller.taskMessage())
        }
    }

    @ViewBuilder private var countingActions: some View {
            if controller.needsRebind {
                FoxCommand(title: "重新就位", icon: "arrow.clockwise", prominent: true) {
                    controller.rebindSubject()
                }.accessibilityIdentifier("vision-rebind")
            } else if controller.isPreparing {
                FoxCommand(title: "取消准备", icon: "xmark") {
                    controller.pauseCounting(); controller.finishDiagnostic(reason: "preparationCancelled")
                }.accessibilityIdentifier("vision-cancel-start")
            } else if controller.isCounting {
                FoxCommand(title: "暂停计数", icon: "pause", prominent: true) { controller.pauseCounting() }.accessibilityIdentifier("vision-pause")
            } else {
                FoxCommand(title: controller.trialActive ? "就位后继续" : "就位后开始", icon: "play.fill", prominent: true) { controller.startCounting() }
                    .disabled(!controller.canCount).accessibilityIdentifier("vision-start")
            }
            if controller.trialActive {
                FoxCommand(title: "结束并核对", icon: "checkmark") {
                    controller.finishCounting(); controller.stopCamera(); reviewing = true
                }
                    .disabled(!controller.canSave).accessibilityIdentifier("vision-finish")
            }
    }

    @ViewBuilder private var diagnosticDetails: some View {
            if UIDevice.current.userInterfaceIdiom == .phone {
                Text(controller.source == .fixture ? "测试数据" : "本机相机").foregroundStyle(.secondary)
                Text("\(controller.latest?.frame.people.count ?? 0) 人 · \(controller.reading.visiblePoints) 个关键点")
            }
            if let reason = controller.snapshot.failureReason {
                Text(reason.label).foregroundStyle(.secondary).accessibilityIdentifier("vision-failure-reason")
            }
            Text("恢复 \(controller.diagnostics.recoveries) · 重置 \(controller.metrics.interruptions)")
                .foregroundStyle(.secondary).accessibilityIdentifier("vision-tracking-diagnostics")
            HStack {
                Text("处理频率").foregroundStyle(.secondary); Spacer()
                Text("\(controller.processingHz.formatted(.number.precision(.fractionLength(1)))) Hz").monospacedDigit()
            }
            HStack {
                Text("Vision 耗时").foregroundStyle(.secondary); Spacer()
                Text(controller.latest.map { "\(Int($0.latencyMs.rounded())) ms" } ?? "未测得").monospacedDigit()
            }
            HStack { Text("热状态").foregroundStyle(.secondary); Spacer(); Text(controller.thermalLabel) }
            if UIDevice.current.userInterfaceIdiom == .phone {
                LabeledContent("屏幕倾角", value: screenAngleText)
                    .accessibilityElement(children: .ignore).accessibilityLabel("屏幕倾角")
                    .accessibilityValue(screenAngleText).accessibilityIdentifier("vision-screen-angle")
            } else {
                HStack {
                    Text("屏幕倾角").foregroundStyle(.secondary); Spacer()
                    Text(screenAngleText).monospacedDigit().accessibilityIdentifier("vision-screen-angle")
                }
            }
            HStack {
                Text("镜头俯仰").foregroundStyle(.secondary); Spacer()
                Text(controller.devicePose.map { "\($0.cameraElevationDegrees >= 0 ? "+" : "")\(Int($0.cameraElevationDegrees.rounded()))°" } ?? "未测得").monospacedDigit()
            }
            HStack {
                Text("躯干占比").foregroundStyle(.secondary); Spacer()
                Text(controller.framing?.torsoHeightFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "未测得").monospacedDigit()
            }
            if let report = controller.lastTrial {
                Divider()
                HStack {
                    Text("最近验证").font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button {
                        exportURL = controller.exportLatest()
                        if showingPhoneOptions && exportURL != nil { shareAfterOptions = true; showingPhoneOptions = false }
                        else { sharing = exportURL != nil }
                    } label: { Image(systemName: "square.and.arrow.up").font(.title2) }.help("导出验证报告").accessibilityLabel("导出验证报告")
                }
                Text("自动 \(report.automaticCount) · 确认 \(report.confirmedCount)").accessibilityIdentifier("vision-last-report")
                Text("\(report.resolvedExercise.label) · \(report.arm.label)").accessibilityIdentifier("vision-last-exercise")
                Text(report.referenceCount.map { "人工参考 \($0) 次" } ?? "未填写人工参考").foregroundStyle(.secondary)
                Text(report.captureContext.map { $0.declaredBodyView == .unknown ? "人体朝向未标注" : "人工标注 · \($0.declaredBodyView.label)" } ?? "旧报告未记录机位")
                    .font(.system(size: 16)).foregroundStyle(.secondary).accessibilityIdentifier("vision-last-body-view")
                Text(report.source == .fixture ? "测试数据" : report.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 16)).foregroundStyle(.secondary)
            }
            Divider()
            VisionDiagnosticControls(controller: controller)
    }

    private func phaseMetric(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 16)).foregroundStyle(.secondary)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) s" } ?? "未测得").font(.system(size: 21, weight: .medium)).monospacedDigit()
        }
    }

    private var screenAngleText: String {
        controller.devicePose.map { "\(Int($0.screenInclinationDegrees.rounded()))°" } ?? "未测得"
    }

    private func resumePreviewIfNeeded() {
        guard cameraViewVisible, scenePhase == .active, !reviewing, !choosingBodyView, !editingParameters, !showingPhoneOptions, !sharing else { return }
        controller.startCamera()
    }
}

struct VisionReportEditor: View {
    private enum InputField: Hashable { case reference, notes }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: VisionLabController
    @State private var reference = ""
    @State private var notes = ""
    @State private var information = ""
    @State private var softwareIssue = ""
    @State private var trainingFeeling = ""
    @State private var error: String?
    @State private var bodyView = VisionBodyView.unknown
    @FocusState private var inputField: InputField?
    var body: some View {
        NavigationStack {
            Form {
                Section("本次结果") {
                    Text("\(controller.exercise.label) · \(controller.arm.label)").font(.headline)
                    HStack {
                        Text("自动 \(controller.automaticCount) · 确认 \(controller.confirmedCount)")
                            .font(.title3.bold()).accessibilityIdentifier("vision-review-counts")
                        Spacer()
                        Button { controller.correct(by: -1) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).disabled(controller.confirmedCount == 0)
                            .accessibilityLabel("确认次数减一").accessibilityIdentifier("vision-review-minus")
                        Button { controller.correct(by: 1) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel("确认次数加一").accessibilityIdentifier("vision-review-plus")
                    }
                    TextField("人工参考次数（可留空）", text: $reference).keyboardType(.numberPad)
                        .focused($inputField, equals: .reference).accessibilityIdentifier("vision-reference-count")
                    Text(measurementSummary).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vision-review-measurement")
                }
                Section("本次录像") { VisionDiagnosticControls(controller: controller, identifierPrefix: "diagnostic-report") }
                Section {
                    DisclosureGroup("补充反馈（可选）") {
                        TrialReviewFields(information: $information, softwareIssue: $softwareIssue, trainingFeeling: $trainingFeeling)
                        TextField("备注", text: $notes, axis: .vertical).focused($inputField, equals: .notes)
                    }.accessibilityIdentifier("vision-review-feedback")
                }
                Section("机位与来源") {
                    Picker("人体朝向", selection: $bodyView) {
                        ForEach(VisionBodyView.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.navigationLink).accessibilityIdentifier("vision-report-body-view")
                    LabeledContent("数据来源", value: controller.source == .fixture ? "测试数据" : "本机相机")
                    LabeledContent("机位样本", value: "\(controller.contextSampleCount)")
                        .accessibilityElement(children: .ignore).accessibilityLabel("机位样本")
                        .accessibilityValue("\(controller.contextSampleCount)").accessibilityIdentifier("vision-context-samples")
                }
                Section("测量") {
                    ReturnIntervalView(rows: ReturnIntervalSummary.make(controller.repetitions, exercise: controller.exercise))
                    LabeledContent("有效帧", value: "\(controller.metrics.validFrames) / \(controller.metrics.processedFrames)")
                    LabeledContent("中断", value: "\(controller.metrics.interruptions)")
                    LabeledContent("Vision P95", value: "\(Int(controller.metrics.latencyP95Ms.rounded())) ms")
                }
                Section("追踪诊断") {
                    LabeledContent("参数", value: controller.diagnostics.configuration.name)
                    LabeledContent("短暂缺失后恢复", value: "\(controller.diagnostics.recoveries)")
                    LabeledContent("数值记录", value: "\(controller.diagnostics.samples.count)")
                    LabeledContent("超出容量", value: "\(controller.diagnostics.droppedSamples)")
                    ForEach(controller.diagnostics.resetCounts.keys.sorted(), id: \.self) { reason in
                        LabeledContent(PoseFailureReason(rawValue: reason)?.label ?? reason,
                                       value: "\(controller.diagnostics.resetCounts[reason] ?? 0)")
                    }
                }
            }.navigationTitle("核对视觉验证").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            inputField = nil
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        } label: { Image(systemName: "keyboard.chevron.compact.down") }
                            .accessibilityLabel("收起键盘").accessibilityIdentifier("vision-dismiss-keyboard")
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do {
                                let review = try TrialReview.make(information: information, softwareIssue: softwareIssue, trainingFeeling: trainingFeeling, at: Date())
                                if controller.saveReport(referenceCount: Int(reference), notes: notes, bodyView: bodyView, review: review) { dismiss() }
                                else { error = controller.errorMessage ?? "验证未保存" }
                            } catch { self.error = error.localizedDescription }
                        }.disabled(!VisionReportInput.validReference(reference) || !controller.canSave).accessibilityIdentifier("vision-save-report")
                    }
                }
                .alert("验证未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("知道了") { error = nil }
                } message: { Text(error ?? "") }
        }.onAppear { bodyView = controller.declaredBodyView }
    }

    private var measurementSummary: String {
        let rows = ReturnIntervalSummary.make(controller.repetitions, exercise: controller.exercise)
        let measured = rows.filter { $0.seconds != nil }.count
        return rows.isEmpty ? "返回区间未测得 · 动作质量未评估" :
            "\(measured) / \(rows.count) 次有可见返回测量 · 非完整离心时长"
    }
}
