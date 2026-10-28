import FoxTrainingCore
import SwiftUI

struct TrainingScreen: View {
    @ObservedObject var store: TrainingStore
    let session: TrainingSession
    let onConfirmed: () -> Void
    var phoneLandscapeNavigation: AnyView? = nil
    @ObservedObject private var visual: VisionLabController
    @ObservedObject private var guidance: GuidanceSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var armChoice: TrainingArmChoice?
    @State private var summaryNote = ""
    @State private var editingRecord: LocalSetRecord?
    @State private var showingDetails = false
    @State private var showingActivityPicker = false
    @ScaledMetric(relativeTo: .title) private var summaryTitleSize = 28
    @ScaledMetric(relativeTo: .title3) private var noteSize = 20

    private var selectedArm: ArmSide { TrainingArmChoice.current(armChoice, session: session) }
    private var armBinding: Binding<ArmSide> {
        Binding(get: { selectedArm }, set: { armChoice = TrainingArmChoice(attemptID: session.currentSetAttemptId, arm: $0) })
    }
    private var hasCamera: Bool { store.usesVision && session.stage != .rest }
    private var preparing: Bool { session.currentObservationId != nil && session.stage != .active }
    private var offersManualContinuation: Bool { hasCamera && (visual.isPreparing || visual.needsRebind) }
    private var canContinuePractice: Bool { !session.records.contains { $0.feedback.contains(.pain) } }
    private var nextActivity: TrainingActivity? { canContinuePractice ? store.nextPractice : nil }

    init(store: TrainingStore, session: TrainingSession, phoneLandscapeNavigation: AnyView? = nil, onConfirmed: @escaping () -> Void) {
        self.store = store; self.session = session; self.onConfirmed = onConfirmed
        self.phoneLandscapeNavigation = phoneLandscapeNavigation
        visual = store.workoutVision.controller; guidance = store.guidance
    }

    var body: some View {
        content
            .onAppear { guidance.start(); store.workoutVision.preview() }
            .onDisappear { guidance.stop(); store.workoutVision.stop() }
            .onChange(of: session.currentSetAttemptId) { _ in store.workoutVision.preview() }
            .onChange(of: session.stage) { stage in
                if stage == .ready { store.workoutVision.preview() }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { guidance.start(); store.workoutVision.preview() }
                else {
                    guidance.stop()
                    if phase == .background { store.workoutVision.stopUnarmedPreview() }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if session.stage == .summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("核对训练记录").font(.system(size: summaryTitleSize, weight: .bold))
                    SessionSummary(session: session) { editingRecord = $0 }
                    TextField("本次训练备注", text: $summaryNote, axis: .vertical).textFieldStyle(.roundedBorder).font(.system(size: noteSize))
                }.padding(28).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("training-summary").scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if canContinuePractice && session.plan.isQuickPractice == true && session.exercise.exerciseId == "dumbbell_curl" && nextActivity == nil {
                        let side: ArmSide = session.exercise.targetSide == .right ? .left : .right
                        Button {
                            if store.confirmSummary(note: summaryNote, nextActivity: .curl, arm: side) { summaryNote = "" }
                        } label: { Label("保存并换\(side.label)", systemImage: "arrow.triangle.swap").frame(minHeight: 44) }
                            .accessibilityIdentifier("save-and-switch-arm")
                    }
                    FoxCommand(title: nextActivity.map { "保存并开始\($0.label)" } ?? "确认并保存", icon: "checkmark", prominent: true) {
                        if store.confirmSummary(note: summaryNote, nextActivity: nextActivity) {
                            summaryNote = ""
                            if store.session == nil { onConfirmed() }
                        }
                    }.accessibilityIdentifier("confirm-summary")
                    if nextActivity != nil {
                        Button("仅保存并结束") {
                            if store.confirmSummary(note: summaryNote) { onConfirmed() }
                        }.frame(minHeight: 44).accessibilityIdentifier("save-without-next")
                    }
                }.padding(16).background(.bar)
            }
            .sheet(item: $editingRecord) { record in
                RecordEditor(record: record) { reps, weight, notes, sides in
                    store.updateSession { try $0.reviseRecord(id: record.id, reps: reps, weight: weight, notes: notes, sideRepetitions: sides) }
                    return store.errorMessage == nil
                }
            }
        } else if session.stage == .feedback {
            SetFeedbackView(store: store, session: session).padding(.horizontal, 20)
        } else {
            GeometryReader { geometry in
                trainingLayout(landscape: UIDevice.current.userInterfaceIdiom == .phone
                    ? FoxAdaptiveLayout.sideBySide(horizontal: sizeClass, vertical: verticalSizeClass) : geometry.size.width >= 850)
            }.sheet(isPresented: $showingDetails) { details }
                .sheet(isPresented: $showingActivityPicker) {
                    NavigationStack {
                        activityPicker.navigationTitle("选择动作").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showingActivityPicker = false }.accessibilityIdentifier("activity-picker-done")
                            } }
                    }
                }
        }
    }

    private func trainingLayout(landscape: Bool) -> some View {
            PhoneCameraLayout(landscape: landscape, spacing: 12, cameraLeading: UIDevice.current.userInterfaceIdiom != .phone) {
                if typeSize.isAccessibilitySize { ScrollView { information(landscape: landscape) }.frame(maxHeight: landscape ? 205 : 300) }
                else { information(landscape: landscape) }
                stage(landscape: landscape)
                HStack(spacing: 10) { actions }.accessibilityElement(children: .contain).accessibilityIdentifier("training-actions")
            }
            .padding(12)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: landscape)
    }

    private func information(landscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if landscape && UIDevice.current.userInterfaceIdiom == .phone { phoneLandscapeNavigation }
            if landscape && typeSize.isAccessibilitySize {
                TimelineView(.periodic(from: .now, by: 0.1)) { observation(at: $0.date) }
            }
            Button { showingActivityPicker = true } label: {
                HStack(spacing: 6) {
                    Text(session.exercise.name).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }.frame(minHeight: 32)
            }.buttonStyle(.plain).accessibilityLabel("选择动作，当前\(session.exercise.name)")
                .accessibilityHint(store.nextPractice.map { "下一动作：\($0.label)，本次保存后开始" } ?? "选择本次或下一次的动作")
                .accessibilityIdentifier("training-activity-picker")
            Text("第 \(session.setIndex + 1) / \(session.exercise.targetSets.count) 组 · 今日 \(session.records.count) / \(session.plan.totalSets) 组")
                .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("phone-training-progress")
            HStack {
                Text(session.target.targetReps.map { "\($0) 次\(session.exercise.targetSide.map { " · \($0.label)" } ?? (session.exercise.repetitionBasis == .perSide ? " / 侧" : ""))" }
                     ?? (durationText(session.target.targetDurationSeconds ?? 0) + (session.exercise.targetSide.map { " · \($0.label)" } ?? "")))
                    .accessibilityIdentifier("phone-target-reps")
                Spacer(minLength: 4)
                Text(weightText(session.currentWeight, unit: session.target.weightUnit)).accessibilityIdentifier("phone-target-weight")
            }.font(.title3.bold()).monospacedDigit()
            if !landscape || !typeSize.isAccessibilitySize {
                TimelineView(.periodic(from: .now, by: 0.1)) { observation(at: $0.date) }
            }
            HStack(spacing: 8) {
                Button { store.setVisionEnabled(!hasCamera) } label: {
                    Image(systemName: hasCamera ? "video" : "video.slash").font(.title3).frame(width: 44, height: 44)
                }.disabled(session.stage == .rest || (!hasCamera && !store.canEnableVision) || session.exercise.visualObservation == nil)
                    .accessibilityLabel(hasCamera ? "关闭视觉" : "开启视觉")
                    .accessibilityIdentifier("training-vision-toggle").help("切换视觉")
                GuidanceMuteButton(session: guidance)
                Button { showingDetails = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel("本组设置").accessibilityIdentifier("phone-training-details").help("本组设置")
                if landscape && offersManualContinuation { manualContinuation(compact: true) }
                Spacer(minLength: 0)
                // Recovery is an additional control, never a replacement for pause or finish.
                Button { store.workoutVision.rebindSubject() } label: {
                    Image(systemName: "arrow.clockwise").font(.title3).frame(width: 44, height: 44)
                }.disabled(!hasCamera || !visual.needsRebind)
                    .accessibilityLabel("重新就位").accessibilityIdentifier("rebind-vision-set").help("重新就位")
            }
            Text(statusDetail).font(.callout).foregroundStyle(.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2).frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                .accessibilityIdentifier(hasCamera ? "workout-task-detail" : "workout-manual-detail")
            if !landscape && offersManualContinuation { manualContinuation(compact: false) }
        }
    }

    private func manualContinuation(compact: Bool) -> some View {
        Button { store.workoutVision.useManual() } label: {
            Group {
                if compact { Text("人工记录") }
                else { Label("人工记录", systemImage: "video.slash") }
            }.font(.headline).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
        }
        .accessibilityIdentifier("training-manual-continue")
        .accessibilityHint("保留已观测次数，继续按计划节奏训练，结束后核对实际完成")
    }

    private var statusDetail: String {
        if hasCamera {
            if session.currentObservationId == nil && session.stage == .ready {
                if session.exercise.visualObservation?.exercise == .curl {
                    return "本组\(selectedArm.label)，请让\(selectedArm == .left ? "左" : "右")侧朝向镜头，准备好后开始。"
                }
                return session.exercise.visualObservation?.exercise.guidance ?? "准备好后开始"
            }
            return visual.taskMessage(automaticCount: session.currentVisualEvidence?.automaticCount ?? 0).detail
        }
        if session.stage == .rest { return "上一组已保存，准备好后继续。" }
        if session.currentVisualEvidence?.fallbackReason != nil { return "已观测次数保留；本组余下次数由你核对，下组可重新开启视觉。" }
        if session.exercise.exerciseId == "kegel" { return "收缩 3 秒，放松 6 秒，正常呼吸；不舒服时停止。" }
        if session.exercise.visualObservation == nil { return "本动作使用计划节奏，结束后确认实际完成。" }
        return store.visionRequested ? "\(visual.cameraState.label)，可按计划节奏训练。" : "视觉已关闭，结束后确认实际完成。"
    }

    private func observation(at date: Date) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.currentVisualEvidence.map { String($0.automaticCount) } ?? (hasCamera ? "0" : "—"))
                    .font(.title2.bold()).monospacedDigit().accessibilityIdentifier("workout-automatic-count")
                Text(hasCamera || session.currentVisualEvidence?.hasObservedFrames == true ? "视觉观测" : "人工核对")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
            }
            Text(hasCamera ? (preparing ? visual.qualityLabel : session.stage == .paused ? "已暂停" :
                session.currentObservationId == nil ? "视觉已开启" : visual.qualityLabel) :
                session.stage == .paused ? "已暂停" : "人工记录")
                .font(.subheadline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("workout-tracking-status")
            Text(durationText(session.elapsed(at: date))).font(.headline).monospacedDigit().fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("set-elapsed")
        }.frame(minHeight: 44)
    }

    private func stage(landscape: Bool) -> some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            // Keep the preview's identity through mode/size changes; only its visibility changes.
            if session.exercise.visualObservation != nil {
                PosePreview(controller: visual).opacity(hasCamera ? 1 : 0)
            }
            if session.stage == .rest {
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    let remaining = session.restRemaining(at: timeline.date)
                    VStack(spacing: 12) {
                        Label(session.records.last?.status == "skipped" ? "跳过已记录" : "上一组已保存", systemImage: "checkmark.circle")
                            .font(.subheadline).accessibilityIdentifier("training-set-saved")
                        Text(remaining > 0 ? "休息" : "准备下一组").font(.headline)
                        Text(durationText(ceil(remaining))).font(.system(size: 48, weight: .semibold)).monospacedDigit()
                            .accessibilityIdentifier("rest-remaining")
                        ProgressView(value: max(0, min(1, 1 - remaining / max(1, session.restDurationSeconds)))).frame(maxWidth: 240)
                    }.padding(12)
                }
            } else {
                TrainingRhythmSquare(output: guidance.output, visual: hasCamera,
                    running: hasCamera ? visual.isCounting : session.stage == .active,
                    paused: session.stage == .paused)
                if case .countdown(let remaining) = visual.startState, hasCamera {
                    Text(String(remaining)).font(.system(size: 72, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white).padding(12).background(.black.opacity(0.7))
                        .accessibilityIdentifier("vision-countdown")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain).accessibilityIdentifier("training-stage-surface")
    }

    @ViewBuilder private var actions: some View {
        if session.stage == .ready || session.stage == .paused {
            FoxCommand(title: preparing ? "取消就位" : session.stage == .paused ? "继续本组" : "开始本组",
                       icon: preparing ? "xmark" : "play.fill", prominent: true) {
                if preparing { _ = store.workoutVision.pause() }
                else if hasCamera { store.workoutVision.prepare(arm: selectedArm) }
                else {
                    if session.currentObservationId != nil { store.workoutVision.useManual() }
                    else { store.updateSession { try $0.startSet(at: Date()) } }
                }
            }.accessibilityIdentifier("begin-set")
            if session.stage == .ready {
                FoxCommand(title: "跳过本组", icon: "forward.end") {
                    if session.currentObservationId != nil && !store.workoutVision.pause() { return }
                    store.workoutVision.stop()
                    store.updateSession { try $0.skip(at: Date()) }
                }.accessibilityIdentifier("skip-set")
            } else {
                FoxCommand(title: "完成本组", icon: "checkmark") { store.workoutVision.finish() }.accessibilityIdentifier("complete-set")
            }
        } else if session.stage == .active {
            FoxCommand(title: "完成本组", icon: "checkmark", prominent: true) { store.workoutVision.finish() }.accessibilityIdentifier("complete-set")
            FoxCommand(title: "暂停", icon: "pause.fill") { _ = store.workoutVision.pause() }.accessibilityIdentifier("pause-set")
        } else if session.stage == .rest {
            FoxCommand(title: "准备下一组", icon: "play.fill", prominent: true) { store.updateSession { try $0.readyAfterRest(at: Date()) } }.accessibilityIdentifier("rest-ready")
            FoxCommand(title: "30 秒", icon: "plus") { store.updateSession { try $0.extendRest(by: 30, at: Date()) } }.accessibilityIdentifier("extend-rest")
        }
    }

    private var details: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(session.exercise.name).font(.title2.bold())
                    Text(statusDetail).foregroundStyle(.secondary)
                    if visual.cameraState == .denied || visual.cameraState == .restricted {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: { Label("打开相机设置", systemImage: "gearshape").frame(minHeight: 44) }
                            .accessibilityIdentifier("vision-open-settings")
                    }
                    NavigationLink { activityPicker.navigationTitle("选择动作") } label: {
                        Label("选择动作 · \(session.exercise.name)", systemImage: "list.bullet")
                    }.accessibilityIdentifier("details-activity-picker")
                    if session.stage == .ready && session.target.weightUnit != "bodyweight" {
                        WeightControl(weight: Binding(get: { session.currentWeight }, set: { value in store.updateSession { try $0.setWeight(value) } }), unit: session.target.weightUnit)
                        Button {
                            if let binding = session.currentSetBinding { store.updateSession { try $0.confirmCurrentWeight(binding: binding, at: Date()) } }
                        } label: { Label(session.currentWeightConfirmation == nil ? "确认本组重量" : "本组重量已确认", systemImage: "checkmark.circle") }
                            .disabled(session.currentWeightConfirmation != nil).accessibilityIdentifier("confirm-set-weight")
                    }
                    if session.exercise.visualObservation?.exercise == .curl {
                        Text("本组\(selectedArm.label)").font(.headline)
                        Button(selectedArm == .left ? "先练右臂" : "先练左臂") {
                            let side: ArmSide = selectedArm == .left ? .right : .left
                            if session.plan.isQuickPractice == true { _ = store.selectActivity(.curl, arm: side) }
                            else { armBinding.wrappedValue = side }
                        }.disabled(!TrainingArmChoice.canChange(session: session))
                            .accessibilityIdentifier("training-other-arm")
                    }
                    if store.visionRequested && session.exercise.visualObservation != nil {
                        Button {
                            store.setVisionEnabled(false); showingDetails = false
                        } label: { Label("关闭视觉 · 人工记录", systemImage: "video.slash") }.accessibilityIdentifier("manual-count")
                    }
                    GuidanceControls(session: guidance, allowsPlannedMode: true)
                    if session.exercise.visualObservation != nil {
                        DisclosureGroup("录像与诊断") {
                            if session.exercise.visualObservation?.exercise != .curl {
                                Text("观察侧：\(selectedArm.label)").font(.callout)
                                Button(selectedArm == .left ? "改为观察右侧" : "改为观察左侧") {
                                    let side: ArmSide = selectedArm == .left ? .right : .left
                                    if session.plan.isQuickPractice == true,
                                       let activity = TrainingActivity(exerciseID: session.exercise.exerciseId) {
                                        _ = store.selectActivity(activity, arm: side)
                                    } else { armBinding.wrappedValue = side }
                                }.disabled(!TrainingArmChoice.canChange(session: session))
                                    .accessibilityIdentifier("diagnostic-other-arm")
                            }
                            VisionDiagnosticControls(controller: visual)
                        }
                            .accessibilityIdentifier("training-diagnostics")
                    }
                    if session.exercise.exerciseId == "kegel", let notes = session.exercise.notes {
                        Text(notes).font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("本组设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingDetails = false }.accessibilityIdentifier("phone-training-details-done") } }
        }
    }

    private var activityPicker: some View {
        TrainingActivityPicker(current: TrainingActivity(exerciseID: session.exercise.exerciseId),
            next: store.nextPractice, canReplace: session.canReplaceQuickPractice) { activity in
                if store.selectActivity(activity) { showingActivityPicker = false; showingDetails = false }
            }
    }
}

// Both modes use the same bounded region. Only fill/contrast differ; presentation still comes
// from the existing guidance engine, never from a second counter or a fabricated return phase.
private struct TrainingRhythmSquare: View {
    @ObservedObject var output: GuidanceOutputController
    let visual: Bool
    let running: Bool
    let paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let side = max(48, min(geometry.size.width, geometry.size.height) * 0.38)
            let state = output.presentation
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(visual ? Color.green.opacity(0.22) : FoxStyle.green)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(visual ? .white.opacity(0.8) : FoxStyle.green, lineWidth: 2))
                    .frame(width: side, height: side)
                    .scaleEffect(running && !reduceMotion ? state.scale : 0.8)
                Text(paused ? "节奏已暂停" : !running ? "待开始" : state.source == .planned ? "计划 · \(state.label)" : state.label)
                    .font(.callout.weight(.semibold)).foregroundStyle(visual ? .white : FoxStyle.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(4).background(visual ? Color.black.opacity(0.55) : Color(uiColor: .secondarySystemGroupedBackground))
                    .accessibilityIdentifier(visual ? "observed-tempo-phase" : "tempo-phase")
            }
            .frame(width: max(1, geometry.size.width - 24), height: geometry.size.height)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .opacity(output.overlayEnabled ? 1 : 0)
            .accessibilityElement(children: .contain).accessibilityIdentifier("training-square-region")
        }.allowsHitTesting(false)
    }
}

struct WeightControl: View {
    @Binding var weight: Double?
    let unit: String?
    @ScaledMetric(relativeTo: .title2) private var valueSize = 26
    @ScaledMetric(relativeTo: .title3) private var unitSize = 20
    var body: some View {
        HStack(spacing: 12) {
            if unit == "bodyweight" {
                Text("自重").font(.system(size: valueSize, weight: .medium))
            } else {
                TextField("重量", value: $weight, format: .number).keyboardType(.decimalPad)
                    .font(.system(size: valueSize, weight: .medium)).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("actual-weight")
                Text(unit == "machine_level" ? "档" : (unit ?? "kg")).font(.system(size: unitSize))
                if unit == nil || unit == "kg" {
                    Menu {
                        Button("未设定") { weight = nil }
                        ForEach([2.5, 5, 7.5, 10, 12.5, 15, 17.5, 20, 22.5, 25], id: \.self) { value in
                            Button("\(value.formatted()) kg") { weight = value }
                        }
                    } label: { Image(systemName: "chevron.down").padding(10) }.accessibilityLabel("选择哑铃重量")
                }
            }
        }
    }
}

struct SetFeedbackView: View {
    @ObservedObject var store: TrainingStore
    let session: TrainingSession
    @State private var reps = ""
    @State private var leftReps = ""
    @State private var rightReps = ""
    @State private var weight: Double?
    @State private var selected: Set<SetFeedback> = []
    @State private var note = ""
    @State private var information = ""
    @State private var softwareIssue = ""
    @State private var feedbackExpanded = false
    @FocusState private var editing: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var headingSize = 26
    @ScaledMetric(relativeTo: .title3) private var observationSize = 20
    @ScaledMetric(relativeTo: .body) private var labelSize = 18
    @ScaledMetric(relativeTo: .largeTitle) private var durationSize = 36

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if verticalSizeClass == .compact {
                    Text("\(session.exercise.name) · 第 \(session.setIndex + 1) 组核对").font(.headline)
                } else { Text("确认本组").font(.system(size: headingSize, weight: .semibold)) }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 40) { actualCount; actualWeight.frame(width: 260); actualDuration }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 16) {
                        actualCount
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) { actualWeight; actualDuration }
                            VStack(alignment: .leading, spacing: 16) { actualWeight; actualDuration }
                        }
                    }
                }
                if let evidence = session.currentVisualEvidence, evidence.hasObservedFrames {
                    Text("观测 \(evidence.settings.arm.label) \(evidence.automaticCount) 次，待你确认").font(.system(size: observationSize)).foregroundStyle(FoxStyle.green)
                    ReturnIntervalView(rows: ReturnIntervalSummary.make(evidence: evidence))
                }
                Text("这一组感觉如何").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(SetFeedback.allCases, id: \.self) { feedback in
                        Toggle(feedback.label, isOn: Binding(get: { selected.contains(feedback) }, set: { enabled in
                            if enabled { selected.insert(feedback) } else { selected.remove(feedback) }
                        })).toggleStyle(.button).buttonStyle(.bordered).font(.body).frame(minHeight: 48)
                            .tint(feedback == .pain ? FoxStyle.coral : FoxStyle.green)
                    }
                }
                DisclosureGroup("补充反馈（可选）", isExpanded: $feedbackExpanded) {
                    TrialReviewFields(information: $information, softwareIssue: $softwareIssue, trainingFeeling: $note)
                }
                Divider()
                if session.exercise.visualObservation != nil {
                    DisclosureGroup("录像与诊断") {
                        VisionDiagnosticControls(controller: store.workoutVision.controller)
                    }
                }
            }.padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("set-feedback")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: { Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44) }
                    .accessibilityLabel("收起键盘").accessibilityIdentifier("feedback-dismiss-keyboard")
                    .help("收起键盘")
                FoxCommand(title: selected.contains(.pain) ? "保存并结束训练" : "保存本组", icon: "checkmark", prominent: true) {
                    editing = false
                    store.updateSession {
                        try $0.setWeight(weight)
                        let sides = session.exercise.repetitionBasis == .perSide ? SideRepetitions(left: Int(leftReps), right: Int(rightReps)) : nil
                        let now = Date()
                        let review = try TrialReview.make(information: information, softwareIssue: softwareIssue, trainingFeeling: note, at: now)
                        try $0.submit(reps: Int(reps), sideRepetitions: sides, feedback: Array(selected), notes: note, at: now, review: review)
                    }
                }.disabled(session.target.targetReps != nil && !TrainingCountInput.canConfirm(
                    session.exercise.repetitionBasis == .perSide ? [leftReps, rightReps] : [reps]))
                    .accessibilityIdentifier("submit-feedback")
            }.padding(.vertical, verticalSizeClass == .compact ? 4 : 12).background(.bar)
        }.onAppear {
            weight = session.currentWeight
            if let evidence = session.currentVisualEvidence, evidence.hasObservedFrames {
                if session.exercise.repetitionBasis == .perSide {
                    if evidence.settings.arm == .left { leftReps = String(evidence.automaticCount) }
                    else { rightReps = String(evidence.automaticCount) }
                } else { reps = String(evidence.automaticCount) }
            }
        }
    }

    @ViewBuilder private var actualCount: some View {
                    if session.target.targetReps != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("实际次数").font(.system(size: labelSize)).foregroundStyle(.secondary)
                            if session.exercise.repetitionBasis == .perSide {
                                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(spacing: 16))) {
                                    if session.exercise.targetSide != .right { VStack(alignment: .leading) {
                                        Text("左臂").font(.system(size: labelSize))
                                        TrainingCountField(text: $leftReps, identifier: "actual-left-reps", label: "左臂次数")
                                    } }
                                    if session.exercise.targetSide != .left { VStack(alignment: .leading) {
                                        Text("右臂").font(.system(size: labelSize))
                                        TrainingCountField(text: $rightReps, identifier: "actual-right-reps", label: "右臂次数")
                                    } }
                                }
                            } else {
                            TrainingCountField(text: $reps, identifier: "actual-reps", label: "实际次数")
                            }
                            if !TrainingCountInput.canConfirm(session.exercise.repetitionBasis == .perSide ? [leftReps, rightReps] : [reps]) {
                                Text("次数待确认").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("feedback-count-required")
                            }
                        }
                    }
    }
    private var actualWeight: some View {
        VStack(alignment: .leading, spacing: 10) {
                        Text("实际重量").font(.system(size: labelSize)).foregroundStyle(.secondary)
                        WeightControl(weight: $weight, unit: session.target.weightUnit).frame(maxWidth: 320)
                    }
    }
    private var actualDuration: some View {
        VStack(alignment: .leading, spacing: 10) {
                        Text("实际用时").font(.system(size: labelSize)).foregroundStyle(.secondary)
                        Text(durationText(session.accumulatedSeconds)).font(.system(size: durationSize, weight: .semibold)).monospacedDigit()
                    }
    }
}

