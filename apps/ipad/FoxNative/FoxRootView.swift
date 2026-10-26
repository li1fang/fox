import FoxTrainingCore
import SwiftUI
import UniformTypeIdentifiers

enum FoxStyle {
    static let ink = Color(red: 0.12, green: 0.15, blue: 0.14)
    static let green = Color(red: 0.12, green: 0.43, blue: 0.31)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.40, green: 0.81, blue: 0.64, alpha: 1) :
            UIColor(red: 0.12, green: 0.43, blue: 0.31, alpha: 1)
    })
    static let coral = Color(red: 0.8, green: 0.25, blue: 0.28)
    static let background = Color(red: 0.96, green: 0.97, blue: 0.97)
}

func durationText(_ seconds: Double) -> String {
    let value = Int(max(0, seconds).rounded(.down))
    return String(format: "%02d:%02d", value / 60, value % 60)
}

func weightText(_ weight: Double?, unit: String? = "kg") -> String {
    if unit == "bodyweight" { return "自重" }
    guard let weight else { return "未设定" }
    let label = unit == "machine_level" ? "档" : (unit ?? "kg")
    return "\(weight.formatted(.number.precision(.fractionLength(0...1)))) \(label)"
}

struct FoxCommand: View {
    let title: String
    let icon: String
    var prominent = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 20, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(prominent ? .white : (destructive ? FoxStyle.coral : FoxStyle.ink))
                .background(prominent ? FoxStyle.green : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(prominent ? Color.clear : Color.gray.opacity(0.25)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

@MainActor
struct FoxRootView: View {
    var onClose: (() -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: TrainingStore
    @StateObject private var vision: VisionLabController
    @State private var tab: String
    init(store: TrainingStore? = nil, vision: VisionLabController? = nil, initialTab: String? = nil, onClose: (() -> Void)? = nil) {
        _store = StateObject(wrappedValue: store ?? TrainingStore())
        _vision = StateObject(wrappedValue: vision ?? VisionLabController())
        _tab = State(initialValue: initialTab ?? (ProcessInfo.processInfo.environment["FOX_START_SCREEN"] == "vision" ? "vision" : "plan"))
        self.onClose = onClose
    }
    @State private var importing = false
    @State private var ending = false
    @State private var sheet: FoxSheet?
    @State private var choosingPhonePage = false
    @State private var savedSessionID: UUID?
    private let heartbeat = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var phoneFocus: Bool { isPhone && (tab == "vision" || (tab == "training" && store.session != nil)) }
    private var trainingFocus: Bool { tab == "vision" || (tab == "training" && store.session != nil) }
    private var phoneLandscapeFocus: Bool {
        isPhone && FoxAdaptiveLayout.sideBySide(horizontal: sizeClass, vertical: verticalSizeClass) && (tab == "vision" ||
            (tab == "training" && store.session.map { [.ready, .active, .paused, .rest].contains($0.stage) } == true))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !phoneLandscapeFocus { Group {
                if trainingFocus { headerActions }
                else if isPhone || sizeClass == .compact {
                    if phoneFocus || (tab == "training" && store.session != nil) {
                        headerActions
                    } else { VStack(spacing: 8) { headerActions; pagePicker } }
                } else {
                    HStack(spacing: 22) {
                        Text("Fox").font(.system(size: 30, weight: .bold)).foregroundStyle(FoxStyle.green)
                        pagePicker
                        headerActions
                    }
                }
            }.padding(.horizontal, isPhone ? 16 : 20).padding(.vertical, phoneFocus || (tab == "training" && store.session?.stage == .feedback && verticalSizeClass == .compact) ? 0 : 10)
            Divider()
            }
            if tab == "vision" {
                VisionLabView(controller: vision, phoneLandscapeNavigation: AnyView(headerActions))
            } else if store.storageUnavailable {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundStyle(FoxStyle.coral)
                    Text("记录暂时无法读取").font(.title2.bold())
                    FoxCommand(title: "导出原文件", icon: "square.and.arrow.up") { sheet = .share(store.fileURL) }.frame(maxWidth: 320)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == "training", let session = store.session {
                TrainingScreen(store: store, session: session, phoneLandscapeNavigation: AnyView(headerActions)) {
                    savedSessionID = session.id; tab = "history"
                }
            } else if tab == "history" {
                history
            } else {
                planView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FoxStyle.background.ignoresSafeArea())
        .tint(FoxStyle.green)
        .foregroundStyle(FoxStyle.ink)
        .preferredColorScheme(.light)
        .onAppear {
            if store.session != nil && tab != "vision" { tab = "training" }
            else if store.session == nil && tab == "training" { tab = "plan" }
            updateIdleTimer()
        }
        .onChange(of: tab) { value in
            if value != "training" && store.session?.currentObservationId != nil { _ = store.workoutVision.pause() }
            if value == "vision" { store.pauseIfActive() }
            updateIdleTimer()
        }
        .onChange(of: store.session?.stage) { value in
            if value != .active && value != .ready && value != .paused { store.workoutVision.stop() }
            updateIdleTimer()
        }
        .onChange(of: store.session?.currentObservationId) { _ in updateIdleTimer() }
        .onChange(of: vision.cameraState) { _ in updateIdleTimer() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            vision.finishDiagnostic(reason: "background")
            store.workoutVision.controller.finishDiagnostic(reason: "background")
            if store.session?.currentObservationId != nil { _ = store.workoutVision.pause() }
            store.pauseIfActive()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                if store.session?.currentObservationId != nil { _ = store.workoutVision.pause() }
                store.pauseIfActive()
            }
            updateIdleTimer()
        }
        .onReceive(heartbeat) { _ in store.checkpoint() }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog("结束这次训练？已完成的组会保留。", isPresented: $ending, titleVisibility: .visible) {
            Button("结束并核对记录", role: .destructive) {
                if !store.workoutVision.flush() { return }
                guard store.updateSession({ try $0.endEarly(at: Date()) }) else { return }
                store.workoutVision.stop()
                tab = "training"
            }
        }
        .confirmationDialog("训练页面", isPresented: $choosingPhonePage, titleVisibility: .visible) {
            Button("计划") { tab = "plan" }
            Button("训练") { tab = store.session == nil ? "plan" : "training" }
            Button("记录") { tab = "history" }
            Button("视觉实验") { tab = "vision" }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): store.importPlan(from: url)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $sheet) { presented in
            switch presented {
            case .editPlan:
                PlanEditor(plan: store.archive.plan) { plan in
                    store.savePlan(plan)
                    return store.errorMessage == nil
                }
            case .record(let session):
                NavigationStack {
                    ScrollView { SessionSummary(session: session).padding(24) }
                        .accessibilityIdentifier("record-detail")
                        .navigationTitle(session.plan.focus)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { sheet = nil } }
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button { if let url = store.export(session) { sheet = .share(url) } } label: { Image(systemName: "square.and.arrow.up") }.help("导出记录")
                            }
                        }
                }
            case .share(let url):
                ShareSheet(url: url)
            }
        }
    }

    private var pagePicker: some View {
        Picker("页面", selection: $tab) {
            Text("计划").tag("plan")
            if store.session != nil { Text("训练").tag("training") }
            Text("记录").tag("history")
        }.pickerStyle(.segmented).frame(maxWidth: isPhone || sizeClass == .compact ? .infinity : 440)
    }

    private var headerActions: some View {
        HStack {
            if onClose != nil {
                Button { closeTraining() } label: {
                    Label("首页", systemImage: "chevron.left").frame(minHeight: isPhone ? 44 : 0).contentShape(Rectangle())
                }
                    .accessibilityIdentifier("training-home")
            } else if isPhone || sizeClass == .compact {
                Text("Fox").font(.title2.bold()).foregroundStyle(FoxStyle.green)
            }
            Spacer()
            if trainingFocus {
                Button { choosingPhonePage = true } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("训练页面").help("训练页面").accessibilityIdentifier("training-page-menu")
            } else {
                Menu {
                    Button { importing = true } label: { Label("导入计划", systemImage: "square.and.arrow.down") }
                    Section("实验与试用") {
                        Button { tab = "vision" } label: { Label("视觉实验", systemImage: "viewfinder") }
                        Button { store.prepareDay1Draft() } label: { Label("准备 Day 1 草稿", systemImage: "calendar.badge.plus") }
                            .accessibilityIdentifier("prepare-day1").disabled(store.session != nil)
                        Button { store.prepareNextTrialDraft() } label: { Label("准备下次试用草稿", systemImage: "list.bullet.clipboard") }
                            .accessibilityIdentifier("prepare-next-trial").disabled(store.session != nil)
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("训练工具").help("训练工具").accessibilityIdentifier("training-tools")
            }
            if store.session != nil {
                Button(role: .destructive) { ending = true } label: { Image(systemName: "stop.circle").font(.title2).frame(width: 44, height: 44) }
                    .accessibilityLabel("结束训练").help("结束训练").disabled(store.session?.stage == .summary)
            }
        }
    }

    private func closeTraining() {
        if store.session?.currentObservationId != nil, !store.workoutVision.pause() { return }
        if store.session?.stage == .active,
           !store.updateSession({ try $0.pause(at: Date()) }) { return }
        if vision.cameraState != .stopped { vision.stopCamera() }
        UIApplication.shared.isIdleTimerDisabled = false
        onClose?()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active &&
            ((tab == "vision" && vision.cameraState == .running) || store.session?.currentObservationId != nil || store.session?.stage == .active || store.session?.stage == .rest)
    }

    private var planView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.archive.plan.focus).font(.system(size: 30, weight: .bold))
                        Text("\(store.archive.plan.exercises.count) 个动作 · \(store.archive.plan.totalSets) 组").font(.system(size: 20)).foregroundStyle(.secondary)
                    }
                    Button { sheet = .editPlan } label: { Label("编辑计划", systemImage: "pencil").frame(minHeight: 44) }
                        .font(.headline).accessibilityIdentifier("edit-training-plan")
                }
                if let date = store.archive.plan.scheduledDate {
                    Text("\(date) · \(store.archive.plan.scheduledTimeZone ?? "")").font(.system(size: 18)).foregroundStyle(.secondary)
                }
                TrainingPlanOutline(plan: store.archive.plan)
            }.padding(24).frame(maxWidth: 1000)
                .frame(maxWidth: .infinity, alignment: .center)
        }.safeAreaInset(edge: .bottom) {
            if store.session != nil {
                FoxCommand(title: "继续未结束的训练", icon: "play.fill", prominent: true) { tab = "training" }
                    .padding(16).background(.bar)
            } else {
                FoxCommand(title: "确认计划并开始", icon: "play.fill", prominent: true) {
                    store.start()
                    if store.session != nil { savedSessionID = nil; tab = "training" }
                }.accessibilityIdentifier("start-training").padding(16).background(.bar)
            }
        }
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let saved = store.archive.sessions.first(where: { $0.id == savedSessionID && $0.isFinished }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("本次训练已保存", systemImage: "checkmark.circle.fill")
                            .font(.title2.bold()).foregroundStyle(FoxStyle.green).accessibilityIdentifier("training-saved-receipt")
                        Text(saved.plan.focus).font(.headline)
                        Text("本机记录 · \(saved.records.count) 组已记录").foregroundStyle(.secondary)
                        Button { sheet = .record(saved) } label: { Label("查看本次记录", systemImage: "list.bullet.rectangle").frame(minHeight: 44) }
                            .accessibilityIdentifier("view-saved-training")
                        if onClose != nil {
                            FoxCommand(title: "返回首页", icon: "house", prominent: true) { closeTraining() }
                                .accessibilityIdentifier("training-saved-home")
                        }
                    }.padding(.vertical, 12)
                    Divider()
                }
                Text("训练记录").font(.system(size: 28, weight: .bold))
                if store.archive.sessions.isEmpty {
                    Text("还没有训练记录").font(.title3).foregroundStyle(.secondary).padding(.vertical, 40)
                }
                ForEach(store.archive.sessions.reversed()) { session in
                    Button {
                        if session.isFinished { sheet = .record(session) } else { tab = "training" }
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: session.isFinished ? "checkmark.circle.fill" : "pause.circle").font(.system(size: 30)).foregroundStyle(session.isFinished ? FoxStyle.green : FoxStyle.coral)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(session.plan.focus).font(.title3.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("training-history-title")
                                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("training-history-date")
                                Text("\(session.records.count) / \(session.plan.totalSets) 组 · \(session.isFinished ? "已确认" : "未结束")")
                                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                        }.padding(.vertical, 18).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("record-\(session.isFinished ? "confirmed" : "pending")")
                    Divider()
                }
            }.padding(28).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
    }
}

struct SessionSummary: View {
    let session: TrainingSession
    var edit: ((LocalSetRecord) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 20)], alignment: .leading, spacing: 16) {
                metric("已完成", value: "\(session.records.filter { $0.status == "completed" }.count) 组")
                metric("部分完成", value: "\(session.records.filter { $0.status == "partial" }.count) 组")
                metric("实际训练", value: durationText(session.records.reduce(0) { $0 + $1.durationSeconds }))
                metric("跳过", value: "\(session.records.filter { $0.status == "skipped" }.count) 组")
            }.padding(.vertical, 10)
            if session.endedEarly { Label("提前结束", systemImage: "stop.circle").foregroundStyle(FoxStyle.coral) }
            ForEach(session.records) { record in
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(record.exerciseName) · 第 \(record.target.setIndex) 组").font(.system(size: 22, weight: .semibold))
                        HStack {
                        Text(record.status == "skipped" ? "已跳过" : (record.status == "partial" ? "部分完成" : "已完成")).foregroundStyle(.secondary)
                        Spacer()
                        if let edit, record.status != "skipped" {
                            Button { edit(record) } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }
                                .buttonStyle(.borderless).accessibilityIdentifier("edit-set-\(record.id)")
                                .help("修改本组记录").accessibilityLabel("修改本组记录")
                        }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.sideRepetitions.map { "左 \($0.left.map(String.init) ?? "未确认") / 右 \($0.right.map(String.init) ?? "未确认") 次" }
                            ?? record.reps.map { "\($0) 次" } ?? (record.status == "skipped" ? "—" : (record.target.targetReps != nil ? "次数未确认" : "计时动作")))
                        Text(weightText(record.weight, unit: record.target.weightUnit))
                        Text(durationText(record.durationSeconds))
                    }.font(.system(size: 21)).monospacedDigit()
                    if let evidence = record.visualEvidence {
                        Text("视觉观测：\(evidence.settings.arm.label) \(evidence.automaticCount) 次").font(.system(size: 18))
                        if evidence.hasIncompleteCoverage { Text("观测不完整").foregroundStyle(.secondary) }
                        if let rhythm = record.rhythmAssessment {
                            let measurable = rhythm.phases.filter { $0.status == .measured }
                            ForEach(["lift", "peak", "lower"], id: \.self) { phase in
                                let samples = measurable.filter { $0.phase == phase }
                                if !samples.isEmpty {
                                    let mean = samples.reduce(0) { $0 + $1.observedSeconds } / Double(samples.count)
                                    Text("\(phase == "lift" ? "抬起" : phase == "peak" ? "顶部" : "下放")阈值段：平均 \(mean.formatted(.number.precision(.fractionLength(1)))) 秒")
                                        .font(.system(size: 17)).foregroundStyle(.secondary)
                                }
                            }
                            Text("完整离心节奏：未评估").font(.system(size: 17)).foregroundStyle(.secondary)
                            if rhythm.status == .estimated { Text("部分阶段有缺失或使用躯干参考，相关节奏偏差未评估").foregroundStyle(.secondary) }
                        }
                        Text("动作质量：未评估").font(.system(size: 17)).foregroundStyle(.secondary)
                        ReturnIntervalView(rows: ReturnIntervalSummary.make(evidence: evidence))
                    }
                    if !record.feedback.isEmpty { Text(record.feedback.map(\.label).joined(separator: " · ")).foregroundStyle(.secondary) }
                    if let review = record.trialReview { TrialReviewSummary(review: review) }
                    if !record.notes.isEmpty && record.notes != record.trialReview?.trainingFeeling { Text(record.notes).foregroundStyle(.secondary) }
                }.padding(.vertical, 12)
                Divider()
            }
            if session.records.count < session.plan.totalSets {
                Text("另有 \(session.plan.totalSets - session.records.count) 组未执行").foregroundStyle(.secondary)
            }
            if !session.summaryNote.isEmpty { Text(session.summaryNote).font(.system(size: 20)) }
        }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 17)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .semibold)).monospacedDigit()
        }
    }
}

enum FoxSheet: Identifiable {
    case editPlan, record(TrainingSession), share(URL)
    var id: String {
        switch self {
        case .editPlan: return "edit-plan"
        case .record(let session): return "record-\(session.id)"
        case .share(let url): return "share-\(url.lastPathComponent)"
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
