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
    @State private var selectedArm: ArmSide
    @State private var summaryNote = ""
    @State private var editingRecord: LocalSetRecord?
    @State private var diagnosticsExpanded = false
    @State private var showingPhoneDetails = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var compactFeedback: Bool { session.stage == .feedback && verticalSizeClass == .compact }

    init(store: TrainingStore, session: TrainingSession, phoneLandscapeNavigation: AnyView? = nil, onConfirmed: @escaping () -> Void) {
        self.store = store; self.session = session; self.onConfirmed = onConfirmed
        self.phoneLandscapeNavigation = phoneLandscapeNavigation
        visual = store.workoutVision.controller
        guidance = store.guidance
        _selectedArm = State(initialValue: session.exercise.visualObservation?.arm ?? .left)
    }

    var body: some View {
        content.onAppear { guidance.start() }.onDisappear { guidance.stop() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { guidance.start() } else { guidance.stop() }
            }
    }

    @ViewBuilder private var content: some View {
        if session.stage == .summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("核对训练记录").font(.system(size: 28, weight: .bold))
                    SessionSummary(session: session) { editingRecord = $0 }
                    TextField("本次训练备注", text: $summaryNote, axis: .vertical).textFieldStyle(.roundedBorder).font(.system(size: 20))
                }.padding(28).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("training-summary")
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                FoxCommand(title: "确认并保存", icon: "checkmark", prominent: true) {
                    store.updateSession { try $0.confirm(note: summaryNote, at: Date()) }
                    if store.session == nil { onConfirmed() }
                }.accessibilityIdentifier("confirm-summary").padding(16).background(.bar)
            }
            .sheet(item: $editingRecord) { record in
                RecordEditor(record: record) { reps, weight, notes, sides in
                    store.updateSession { try $0.reviseRecord(id: record.id, reps: reps, weight: weight, notes: notes, sideRepetitions: sides) }
                    return store.errorMessage == nil
                }
            }
        } else if UIDevice.current.userInterfaceIdiom == .phone && session.stage != .feedback {
            phoneTrainingBody
                .onChange(of: session.currentSetAttemptId) { _ in selectedArm = session.exercise.visualObservation?.arm ?? .left }
                .sheet(isPresented: $showingPhoneDetails) { phoneDetails }
        } else {
            VStack(spacing: compactFeedback ? 0 : 18) {
                if !compactFeedback {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) { heading; progress.fixedSize() }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 10) { heading; progress }
                }
                }
                if session.stage == .feedback {
                    SetFeedbackView(store: store, session: session)
                } else {
                    GeometryReader { geometry in
                        if geometry.size.height < 260 && !typeSize.isAccessibilitySize {
                            ScrollView {
                                VStack(spacing: 16) { compactPerformancePanel; targets }
                            }.accessibilityIdentifier("training-observation")
                        } else if geometry.size.width >= 850 && !typeSize.isAccessibilitySize {
                            HStack(spacing: 28) {
                                ScrollView { performancePanel }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                ScrollView { targets }.frame(width: 300)
                            }
                        } else {
                            ScrollView {
                                VStack(spacing: 20) {
                                    performancePanel
                                    targets
                                }.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, compactFeedback ? 0 : 20)
                .safeAreaInset(edge: .bottom) {
                    if session.stage != .feedback {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: actionColumnCount), spacing: 10) { actions }
                            .padding(16).background(.bar).accessibilityIdentifier("training-actions")
                    }
                }
                .onChange(of: session.currentSetAttemptId) { _ in selectedArm = session.exercise.visualObservation?.arm ?? .left }
        }
    }

    private var usesPhoneCamera: Bool {
        session.stage != .rest && session.exercise.visualObservation != nil && session.currentVisualEvidence?.fallbackReason == nil
    }

    private var phoneTrainingBody: some View {
        let landscape = verticalSizeClass == .compact
        let actionsLayout = landscape ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return PhoneCameraLayout(landscape: landscape, spacing: landscape ? 12 : 8) {
            VStack(spacing: 6) {
                if landscape { phoneLandscapeNavigation }
                if landscape && typeSize.isAccessibilitySize { ScrollView { phoneSidebarInformation } }
                else { phoneSidebarInformation }
            }
            GeometryReader { stage in phoneStage(size: stage.size) }
            actionsLayout { phoneActions }
        }
        .padding(.horizontal, landscape ? 12 : 16).padding(.vertical, landscape ? 12 : 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: landscape)
    }

    private var phoneSidebarInformation: some View {
        VStack(spacing: 6) {
            phoneHeading
            phoneTargets
            if verticalSizeClass == .compact && usesPhoneCamera {
                if session.stage == .ready || session.stage == .paused {
                    Picker("观测手臂", selection: $selectedArm) {
                        ForEach(ArmSide.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).disabled(session.currentVisualEvidence != nil)
                        .accessibilityIdentifier("workout-quick-arm")
                }
                TimelineView(.periodic(from: .now, by: 0.1)) { phoneObservation(at: $0.date) }
                TrainingRecordingStatus(capture: visual.diagnosticCapture)
            }
        }
    }

    private var phoneHeading: some View {
        HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.exercise.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("第 \(session.setIndex + 1) / \(session.exercise.targetSets.count) 组 · 今日 \(session.records.count) / \(session.plan.totalSets) 组")
                        .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("phone-training-progress")
                }.frame(maxWidth: .infinity, alignment: .leading)
                if usesPhoneCamera { GuidanceMuteButton(session: guidance) }
                Button { showingPhoneDetails = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.title2).frame(width: 44, height: 44)
                }.accessibilityLabel("本组设置").accessibilityIdentifier("phone-training-details").help("本组设置")
            }
    }

    private var phoneTargets: some View {
        HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.stage == .rest ? "下一组目标" : "本组目标").font(.caption).foregroundStyle(.secondary)
                    Text(session.target.targetReps.map { "\($0) 次\(session.exercise.repetitionBasis == .perSide ? " / 侧" : "")" } ?? durationText(session.target.targetDurationSeconds ?? 0))
                        .font(.title3.bold()).monospacedDigit().accessibilityIdentifier("phone-target-reps")
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.stage == .ready && session.currentWeightConfirmation == nil ? "重量待确认" : "重量").font(.caption).foregroundStyle(.secondary)
                    Text(weightText(session.currentWeight, unit: session.target.weightUnit)).font(.title3.weight(.semibold))
                        .accessibilityIdentifier("phone-target-weight")
                }.onTapGesture { if session.stage == .ready { showingPhoneDetails = true } }
            }.padding(.vertical, 4)
    }

    @ViewBuilder private func phoneStage(size: CGSize) -> some View {
        if usesPhoneCamera {
            VStack(spacing: 6) {
                if verticalSizeClass != .compact {
                    TimelineView(.periodic(from: .now, by: 0.1)) { phoneObservation(at: $0.date) }
                }
                phoneWorkoutCamera
                if verticalSizeClass != .compact { TrainingRecordingStatus(capture: visual.diagnosticCapture) }
            }
        } else {
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                if session.stage == .rest { phoneRest(at: timeline.date, short: size.height < 230) }
                else { phoneManual(at: timeline.date, size: size) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func phoneObservation(at date: Date) -> some View {
        HStack(spacing: 12) {
            Text("\(session.currentVisualEvidence?.automaticCount ?? 0)").font(.title.bold()).monospacedDigit()
                .accessibilityIdentifier("workout-automatic-count")
            VStack(alignment: .leading, spacing: 2) {
                Text((session.currentVisualEvidence?.settings.arm ?? selectedArm).label).font(.caption)
                Text(session.stage == .paused ? "已暂停" : session.currentObservationId == nil ? "相机待机" : visual.qualityLabel)
                    .font(.subheadline).accessibilityIdentifier("workout-tracking-status")
            }.foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text(durationText(session.elapsed(at: date))).font(.headline).monospacedDigit()
                .accessibilityIdentifier("set-elapsed")
        }
    }

    private var phoneWorkoutCamera: some View {
        PhoneCameraStage(controller: visual, idleLabel: session.currentObservationId == nil ? (session.stage == .paused ? "已暂停" : "相机待机") : nil,
            guidance: guidance)
    }

    private func phoneManual(at date: Date, size: CGSize) -> some View {
        let elapsed = session.elapsed(at: date)
        let short = size.height < 230
        return Group {
            if short {
                HStack(spacing: 24) {
                    phoneClock(elapsed: elapsed)
                    TempoDisplay(tempo: session.exercise.tempo, elapsed: elapsed, running: session.stage == .active,
                                 drawingSize: max(32, min(90, size.height - 48)))
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 24) {
                    phoneClock(elapsed: elapsed)
                    TempoDisplay(tempo: session.exercise.tempo, elapsed: elapsed, running: session.stage == .active,
                                 drawingSize: max(64, min(170, size.height - 180)))
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func phoneClock(elapsed: Double) -> some View {
        VStack(spacing: 6) {
            Text(session.stage == .active ? "本组用时" : session.stage == .paused ? "已暂停" : "准备开始")
                .font(.subheadline).foregroundStyle(FoxStyle.green).accessibilityIdentifier("training-stage")
            Text(durationText(elapsed)).font(.system(size: 42, weight: .semibold)).monospacedDigit()
                .accessibilityIdentifier("set-elapsed")
            if session.currentVisualEvidence?.fallbackReason != nil {
                Text("人工记录中").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("workout-tracking-status")
            }
        }.frame(maxWidth: .infinity)
    }

    private func phoneRest(at date: Date, short: Bool) -> some View {
        let rest = session.restRemaining(at: date)
        return VStack(spacing: short ? 8 : 20) {
            Text(rest > 0 ? "休息" : "准备下一组").font(.headline).foregroundStyle(FoxStyle.green)
            Text(durationText(ceil(rest))).font(.system(size: short ? 42 : 72, weight: .semibold)).monospacedDigit()
                .accessibilityIdentifier("rest-remaining")
            ProgressView(value: max(0, min(1, 1 - rest / max(1, session.restDurationSeconds))))
                .frame(maxWidth: 300)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var phoneDetails: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    targets
                    if session.stage == .ready && session.exercise.visualObservation != nil && session.currentVisualEvidence?.fallbackReason == nil {
                        FoxCommand(title: "跳过本组", icon: "forward.end") {
                            showingPhoneDetails = false; store.updateSession { try $0.skip(at: Date()) }
                        }.accessibilityIdentifier("skip-set")
                    }
                    if (session.stage == .active && session.currentObservationId != nil) || (session.stage == .paused && usesPhoneCamera) {
                        FoxCommand(title: "改为人工记录", icon: "hand.tap") {
                            store.workoutVision.useManual(); showingPhoneDetails = false
                        }.accessibilityIdentifier("manual-count")
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("本组设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingPhoneDetails = false }.accessibilityIdentifier("phone-training-details-done") } }
        }
    }

    @ViewBuilder private var phoneActions: some View {
        if session.stage == .ready || session.stage == .paused {
            if usesPhoneCamera {
                if session.currentObservationId == nil {
                    FoxCommand(title: "就位后开始", icon: "viewfinder", prominent: true) { store.workoutVision.prepare(arm: selectedArm) }
                        .accessibilityIdentifier("begin-vision-set")
                    if session.stage == .paused {
                        FoxCommand(title: "完成本组", icon: "checkmark") { store.workoutVision.finish() }.accessibilityIdentifier("complete-set")
                    } else {
                        FoxCommand(title: "人工开始", icon: "hand.tap") { store.updateSession { try $0.startSet(at: Date()) } }
                            .accessibilityIdentifier("begin-set")
                    }
                } else {
                    if visual.needsRebind { rebindAction } else {
                        FoxCommand(title: "取消就位", icon: "xmark") { _ = store.workoutVision.pause() }
                            .accessibilityIdentifier("cancel-vision-preparation")
                    }
                    FoxCommand(title: "人工记录", icon: "hand.tap") { store.workoutVision.useManual() }
                        .accessibilityIdentifier("manual-count")
                }
            } else {
                FoxCommand(title: session.stage == .paused ? "继续本组" : "开始本组", icon: "play.fill", prominent: true) {
                    store.updateSession { try $0.startSet(at: Date()) }
                }.accessibilityIdentifier("begin-set")
                if session.stage == .ready {
                    FoxCommand(title: "跳过本组", icon: "forward.end") { store.updateSession { try $0.skip(at: Date()) } }.accessibilityIdentifier("skip-set")
                } else {
                    FoxCommand(title: "完成本组", icon: "checkmark") { store.workoutVision.finish() }.accessibilityIdentifier("complete-set")
                }
            }
        } else if session.stage == .active {
            FoxCommand(title: "完成本组", icon: "checkmark", prominent: true) { store.workoutVision.finish() }.accessibilityIdentifier("complete-set")
            if visual.needsRebind { rebindAction } else {
                FoxCommand(title: "暂停", icon: "pause.fill") { _ = store.workoutVision.pause() }.accessibilityIdentifier("pause-set")
            }
        } else if session.stage == .rest {
            FoxCommand(title: "准备好了", icon: "play.fill", prominent: true) { store.updateSession { try $0.readyAfterRest(at: Date()) } }.accessibilityIdentifier("rest-ready")
            FoxCommand(title: "+30 秒", icon: "plus") { store.updateSession { try $0.extendRest(by: 30, at: Date()) } }.accessibilityIdentifier("extend-rest")
        }
    }

    private var rebindAction: some View {
        FoxCommand(title: "重新就位", icon: "arrow.clockwise") { store.workoutVision.rebindSubject() }
            .accessibilityIdentifier("rebind-vision-set")
    }

    private var actionColumnCount: Int {
        if typeSize.isAccessibilitySize { return 1 }
        let third = (session.stage == .ready || session.stage == .paused)
            ? session.exercise.visualObservation != nil && session.currentVisualEvidence?.fallbackReason == nil
            : session.stage == .active && session.currentObservationId != nil
        return sizeClass == .compact ? 2 : (third ? 3 : 2)
    }

    private var compactPerformancePanel: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let elapsed = session.elapsed(at: timeline.date)
            HStack(spacing: 24) {
                if session.stage == .rest {
                    Text(durationText(ceil(session.restRemaining(at: timeline.date))))
                        .font(.system(size: 48, weight: .semibold)).monospacedDigit()
                    Text("休息 · 下一组").font(.headline)
                } else if let evidence = session.currentVisualEvidence {
                    Text(String(evidence.automaticCount)).font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit().frame(minWidth: 90).accessibilityIdentifier("workout-automatic-count")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(evidence.settings.arm.label).font(.headline)
                        Text(evidence.fallbackReason != nil ? "人工记录中" : visual.qualityLabel).font(.callout)
                            .accessibilityIdentifier("workout-tracking-status")
                        Text(durationText(elapsed)).font(.title3).monospacedDigit().accessibilityIdentifier("set-elapsed")
                    }
                    TrainingRecordingStatus(capture: visual.diagnosticCapture)
                } else {
                    Text(durationText(elapsed)).font(.system(size: 48, weight: .semibold)).monospacedDigit()
                        .accessibilityIdentifier("set-elapsed")
                    Text(session.stage == .active ? "本组用时" : session.stage == .paused ? "已暂停" : "准备开始")
                        .font(.headline).accessibilityIdentifier("training-stage")
                }
                if session.stage != .rest {
                    TempoDisplay(tempo: session.exercise.tempo, elapsed: elapsed, running: session.stage == .active, compact: true)
                        .frame(width: 90, height: 78)
                }
            }.frame(maxWidth: .infinity).frame(minHeight: 80)
        }
    }

    private var heading: some View {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.exercise.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        Text("第 \(session.setIndex + 1) / \(session.exercise.targetSets.count) 组 · 动作 \(session.exerciseIndex + 1) / \(session.plan.exercises.count)").font(.body).foregroundStyle(.secondary)
                    }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("今日进度 \(session.records.count) / \(session.plan.totalSets) 组").font(.callout)
            ProgressView(value: session.progress).frame(maxWidth: 200)
        }
    }

    private var performancePanel: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let elapsed = session.elapsed(at: timeline.date)
            let rest = session.restRemaining(at: timeline.date)
            VStack(spacing: 18) {
                if session.stage == .rest {
                    Text(rest > 0 ? "休息" : "准备下一组").font(.system(size: 26, weight: .semibold)).foregroundStyle(FoxStyle.green)
                    Text(durationText(ceil(rest))).font(.system(size: 100, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6)
                    ProgressView(value: max(0, min(1, 1 - rest / max(1, session.restDurationSeconds)))).frame(maxWidth: 480)
                } else if session.currentVisualEvidence != nil {
                    VStack(spacing: 12) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 22) { cameraPreview.frame(width: 230); observedCount }
                            VStack(spacing: 12) { observedCount; cameraPreview }
                        }
                        if case .countdown(let remaining) = visual.startState {
                            Text(String(remaining)).font(.system(size: 64, weight: .bold)).monospacedDigit()
                        } else if visual.isPreparing {
                            Text(visual.qualityLabel).font(.title2.bold()).foregroundStyle(FoxStyle.green)
                        } else if session.stage == .paused && session.currentObservationId == nil {
                            Text("已暂停").font(.system(size: 24, weight: .semibold)).foregroundStyle(FoxStyle.green)
                        } else {
                            TempoDisplay(tempo: session.exercise.tempo, elapsed: elapsed, running: session.stage == .active)
                                .frame(width: 180, height: 200)
                        }
                        Text("本组用时 \(durationText(elapsed))").font(.title2.bold()).monospacedDigit()
                            .accessibilityIdentifier("set-elapsed")
                    }
                } else {
                    Text(session.stage == .active ? "节奏提示" : (session.stage == .paused ? "已暂停" : "准备开始"))
                        .font(.title3.bold()).foregroundStyle(FoxStyle.green).accessibilityIdentifier("training-stage")
                    VStack(spacing: 6) {
                        Text("本组用时").font(.body).foregroundStyle(.secondary)
                        Text(durationText(elapsed)).font(.system(size: 44, weight: .semibold)).monospacedDigit().accessibilityIdentifier("set-elapsed")
                    }
                    TempoDisplay(tempo: session.exercise.tempo, elapsed: elapsed, running: session.stage == .active)
                        .frame(width: 220, height: 220)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var cameraPreview: some View {
        PosePreview(controller: visual).frame(maxWidth: 330).frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if let frame = visual.latest?.frame {
                    GuidanceCameraOverlay(output: guidance.output, imageSize: CGSize(width: frame.width, height: frame.height), active: visual.isCounting)
                }
            }
            .overlay(alignment: .topTrailing) { GuidanceMuteButton(session: guidance).padding(6) }
            .overlay(alignment: .topLeading) {
                TrainingRecordingStatus(capture: visual.diagnosticCapture).padding(6)
            }
    }
    private var observedCount: some View {
                            VStack(spacing: 4) {
                                Text(session.currentVisualEvidence?.settings.arm.label ?? "观测").font(.title3)
                                Text(String(session.currentVisualEvidence?.automaticCount ?? 0))
                                    .font(.system(size: 84, weight: .bold, design: .rounded)).monospacedDigit()
                                    .accessibilityIdentifier("workout-automatic-count")
                                Text(session.currentVisualEvidence?.fallbackReason != nil ? "人工记录中" : visual.qualityLabel)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("workout-tracking-status")
                            }
    }

    private var targets: some View {
        VStack(alignment: .leading, spacing: 24) {
            DisclosureGroup("视听引导") { GuidanceControls(session: guidance, allowsPlannedMode: true).padding(.top, 8) }
            Text(session.stage == .rest ? "下一组目标" : "本组目标").font(.system(size: 20)).foregroundStyle(.secondary)
            Text(session.target.targetReps.map { "\($0) 次\(session.exercise.repetitionBasis == .perSide ? " / 侧" : "")" } ?? durationText(session.target.targetDurationSeconds ?? 0))
                .font(.system(size: 56, weight: .bold)).monospacedDigit()
            if session.stage == .ready {
                WeightControl(weight: Binding(get: { session.currentWeight }, set: { weight in store.updateSession { try $0.setWeight(weight) } }), unit: session.target.weightUnit)
                if let binding = session.currentSetBinding {
                    Button {
                        store.updateSession { try $0.confirmCurrentWeight(binding: binding, at: Date()) }
                    } label: {
                        Label(session.currentWeightConfirmation == nil ? "确认本组重量" : "本组重量已确认",
                              systemImage: session.currentWeightConfirmation == nil ? "checkmark.circle" : "checkmark.circle.fill")
                    }.disabled(session.currentWeightConfirmation != nil)
                        .accessibilityIdentifier("confirm-set-weight")
                }
            } else {
                Text(weightText(session.currentWeight, unit: session.target.weightUnit)).font(.system(size: 26, weight: .medium))
            }
            if session.stage == .ready || session.stage == .paused {
                if session.exercise.visualObservation != nil, session.currentVisualEvidence?.fallbackReason == nil {
                    Picker("观察侧", selection: $selectedArm) {
                        Text("左臂").tag(ArmSide.left); Text("右臂").tag(ArmSide.right)
                    }.pickerStyle(.segmented).disabled(session.currentVisualEvidence != nil).accessibilityIdentifier("workout-observation-arm")
                    Text(session.exercise.visualObservation?.exercise.guidance ?? "").font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }
            if session.exercise.visualObservation != nil || visual.diagnosticCapture.isActive || !visual.diagnosticCapture.packages.isEmpty {
                Divider()
                DisclosureGroup("录像与诊断", isExpanded: $diagnosticsExpanded) { VisionDiagnosticControls(controller: visual) }
                    .font(.callout).accessibilityIdentifier("training-diagnostics")
            }
        }.padding(.vertical, 16)
    }

    @ViewBuilder private var actions: some View {
            if session.stage == .ready || session.stage == .paused {
                if session.exercise.visualObservation != nil, session.currentVisualEvidence?.fallbackReason == nil {
                    if session.currentObservationId == nil {
                        FoxCommand(title: "就位后开始", icon: "viewfinder", prominent: true) { store.workoutVision.prepare(arm: selectedArm) }
                            .accessibilityIdentifier("begin-vision-set")
                    } else {
                        if visual.needsRebind { rebindAction } else {
                            FoxCommand(title: "取消就位", icon: "xmark") { _ = store.workoutVision.pause() }
                                .accessibilityIdentifier("cancel-vision-preparation")
                        }
                    }
                }
                if session.currentObservationId != nil {
                    FoxCommand(title: "改为人工记录", icon: "hand.tap") { store.workoutVision.useManual() }.accessibilityIdentifier("manual-count")
                } else {
                    let canUseVision = session.exercise.visualObservation != nil && session.currentVisualEvidence?.fallbackReason == nil
                    FoxCommand(title: canUseVision ? (session.stage == .paused ? "人工继续本组" : "人工开始本组") :
                        (session.stage == .paused ? "继续本组" : "开始本组"), icon: canUseVision ? "hand.tap" : "play.fill", prominent: !canUseVision) {
                        store.updateSession { try $0.startSet(at: Date()) }
                    }.accessibilityIdentifier("begin-set")
                }
                if session.stage == .ready {
                    FoxCommand(title: "跳过本组", icon: "forward.end") { store.updateSession { try $0.skip(at: Date()) } }.accessibilityIdentifier("skip-set")
                } else {
                    FoxCommand(title: "完成本组", icon: "checkmark") { store.workoutVision.finish() }.accessibilityIdentifier("complete-set")
                }
            } else if session.stage == .active {
                FoxCommand(title: "完成本组", icon: "checkmark", prominent: true) { store.workoutVision.finish() }.accessibilityIdentifier("complete-set")
                if visual.needsRebind { rebindAction } else {
                    FoxCommand(title: "暂停", icon: "pause.fill") { _ = store.workoutVision.pause() }.accessibilityIdentifier("pause-set")
                }
                if session.currentObservationId != nil {
                    FoxCommand(title: "改为人工记录", icon: "hand.tap") { store.workoutVision.useManual() }.accessibilityIdentifier("manual-count")
                }
            } else if session.stage == .rest {
                FoxCommand(title: "准备好了", icon: "play.fill", prominent: true) { store.updateSession { try $0.readyAfterRest(at: Date()) } }.accessibilityIdentifier("rest-ready")
                FoxCommand(title: "再休息 30 秒", icon: "plus") { store.updateSession { try $0.extendRest(by: 30, at: Date()) } }.accessibilityIdentifier("extend-rest")
            }
    }
}

private struct TrainingRecordingStatus: View {
    @ObservedObject var capture: VisionDiagnosticStore
    var body: some View {
        if capture.isActive || capture.finishing {
            Label(capture.status, systemImage: capture.isActive ? "record.circle" : "hourglass")
                .font(.caption).padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityIdentifier("training-recording-status")
        }
    }
}

struct WeightControl: View {
    @Binding var weight: Double?
    let unit: String?
    var body: some View {
        HStack(spacing: 12) {
            if unit == "bodyweight" {
                Text("自重").font(.system(size: 26, weight: .medium))
            } else {
                TextField("重量", value: $weight, format: .number).keyboardType(.decimalPad)
                    .font(.system(size: 26, weight: .medium)).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("actual-weight")
                Text(unit == "machine_level" ? "档" : (unit ?? "kg")).font(.system(size: 20))
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
    @FocusState private var editing: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if verticalSizeClass == .compact {
                    Text("\(session.exercise.name) · 第 \(session.setIndex + 1) 组核对").font(.headline)
                } else { Text("确认本组").font(.system(size: 26, weight: .semibold)) }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 40) { actualCount; actualWeight.frame(width: 260); actualDuration }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 24) { actualCount; actualWeight.frame(maxWidth: 320); actualDuration }
                }
                if let evidence = session.currentVisualEvidence, evidence.hasObservedFrames {
                    Text("观测 \(evidence.settings.arm.label) \(evidence.automaticCount) 次，待你确认").font(.system(size: 20)).foregroundStyle(FoxStyle.green)
                    ReturnIntervalView(rows: ReturnIntervalSummary.make(evidence: evidence))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                    ForEach(SetFeedback.allCases, id: \.self) { feedback in
                        Toggle(feedback.label, isOn: Binding(get: { selected.contains(feedback) }, set: { enabled in
                            if enabled { selected.insert(feedback) } else { selected.remove(feedback) }
                        })).toggleStyle(.button).font(.system(size: 20)).frame(minHeight: 48)
                            .tint(feedback == .pain ? FoxStyle.coral : FoxStyle.green)
                    }
                }
                TrialReviewFields(information: $information, softwareIssue: $softwareIssue, trainingFeeling: $note)
                Divider()
                VisionDiagnosticControls(controller: store.workoutVision.controller)
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
                }.disabled(session.target.targetReps != nil && (session.exercise.repetitionBasis == .perSide
                    ? Int(leftReps) == nil && Int(rightReps) == nil : Int(reps) == nil)).accessibilityIdentifier("submit-feedback")
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
                            Text("实际次数").font(.system(size: 18)).foregroundStyle(.secondary)
                            if session.exercise.repetitionBasis == .perSide {
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading) {
                                        Text("左臂").font(.system(size: 18))
                                        TextField("次数", text: $leftReps).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                                            .font(.system(size: 32, weight: .semibold)).frame(width: 110).accessibilityIdentifier("actual-left-reps")
                                    }
                                    VStack(alignment: .leading) {
                                        Text("右臂").font(.system(size: 18))
                                        TextField("次数", text: $rightReps).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                                            .font(.system(size: 32, weight: .semibold)).frame(width: 110).accessibilityIdentifier("actual-right-reps")
                                    }
                                }
                            } else {
                            TextField("次数", text: $reps).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                                .font(.system(size: 36, weight: .semibold)).frame(maxWidth: 220).accessibilityIdentifier("actual-reps")
                            }
                        }
                    }
    }
    private var actualWeight: some View {
        VStack(alignment: .leading, spacing: 10) {
                        Text("实际重量").font(.system(size: 18)).foregroundStyle(.secondary)
                        WeightControl(weight: $weight, unit: session.target.weightUnit).frame(maxWidth: 320)
                    }
    }
    private var actualDuration: some View {
        VStack(alignment: .leading, spacing: 10) {
                        Text("实际用时").font(.system(size: 18)).foregroundStyle(.secondary)
                        Text(durationText(session.accumulatedSeconds)).font(.system(size: 36, weight: .semibold)).monospacedDigit()
                    }
    }
}

