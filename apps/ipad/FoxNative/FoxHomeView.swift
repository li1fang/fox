import FoxJournalCore
import FoxTrainingCore
import SwiftUI

private struct HomeCardIdentity: LayoutValueKey { static let defaultValue = "" }

private struct HomeMasonry: Layout {
    let columns: Int
    let spacing: CGFloat = 16
    struct Cache { var columns = 0; var assignments: [String: Int] = [:] }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        let keys = Set(subviews.indices.map { subviews[$0][HomeCardIdentity.self].isEmpty ? "item-\($0)" : subviews[$0][HomeCardIdentity.self] })
        cache.assignments = cache.assignments.filter { keys.contains($0.key) }
    }

    private func positions(width: CGFloat, subviews: Subviews, cache: inout Cache) -> (points: [CGPoint], height: CGFloat) {
        // Column affinity prevents composer growth from moving cards sideways. It does not
        // guarantee that a reordered source array has the same visual or VoiceOver reading order.
        if cache.columns != columns { cache.columns = columns; cache.assignments = [:] }
        let keys = subviews.indices.map { subviews[$0][HomeCardIdentity.self].isEmpty ? "item-\($0)" : subviews[$0][HomeCardIdentity.self] }
        let visibleKeys = Set(keys)
        cache.assignments = cache.assignments.filter { visibleKeys.contains($0.key) }
        let cellWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var heights = Array(repeating: CGFloat.zero, count: columns)
        var points: [CGPoint] = []
        for (index, subview) in subviews.enumerated() {
            let column = cache.assignments[keys[index]] ?? heights.indices.min(by: { heights[$0] < heights[$1] }) ?? 0
            cache.assignments[keys[index]] = column
            points.append(CGPoint(x: CGFloat(column) * (cellWidth + spacing), y: heights[column]))
            heights[column] += subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height + spacing
        }
        return (points, max(0, (heights.max() ?? 0) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 360
        return CGSize(width: width, height: positions(width: width, subviews: subviews, cache: &cache).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let points = positions(width: bounds.width, subviews: subviews, cache: &cache).points
        let width = max(0, (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y),
                anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
        }
    }
}

struct HomeCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.06)))
    }
}

@MainActor
struct FoxHomeView: View {
    @StateObject private var journal: JournalStore
    @StateObject private var photos: JournalPhotoSelection
    @StateObject private var trainingArchive: HomeTrainingStore
    @StateObject private var serviceCards: HomeServiceCardStore
    @StateObject private var trainingDispatcher = HomeTrainingDispatcher()
    @State private var servicePresentation: HomeTrainingDispatcher.Presentation?
    @State private var serviceRecoveryError: String?
    private let automaticallyLoad: Bool
    init(journal: JournalStore? = nil, photos: JournalPhotoSelection? = nil, trainingArchive: HomeTrainingStore? = nil, automaticallyLoad: Bool = true, serviceCards: HomeServiceCardStore? = nil) {
        _journal = StateObject(wrappedValue: journal ?? JournalStore()); _photos = StateObject(wrappedValue: photos ?? JournalPhotoSelection())
        _trainingArchive = StateObject(wrappedValue: trainingArchive ?? HomeTrainingStore())
        _serviceCards = StateObject(wrappedValue: serviceCards ?? ClientServiceFixture.makeIfEnabled() ?? HomeServiceCardStore())
        self.automaticallyLoad = automaticallyLoad
    }
    @FocusState private var editing: Bool
    @State private var selected: CaptureRecord?
    @State private var trainingRoute: TrainingEntry?
    @State private var showingHistory = false
    @State private var showingCapabilities = false
    @State private var showingBackup = false
    @State private var trainingSelection: HomeTrainingSelection?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    HomeMasonry(columns: columnCount(geometry.size.width)) {
                        composer.layoutValue(key: HomeCardIdentity.self, value: "composer")
                        training.layoutValue(key: HomeCardIdentity.self, value: "training")
                        if let plan = trainingArchive.snapshot.plan {
                            trainingProjection(title: "本机计划 · 开始前确认", name: plan.focus,
                                detail: plan.scheduledDate.map { "\($0) · \(plan.scheduledTimeZone ?? "")" } ?? "未安排日期",
                                count: "\(plan.exercises.count) 个动作 · \(plan.totalSets) 组", id: "plan") { trainingSelection = .plan(plan) }
                                .layoutValue(key: HomeCardIdentity.self, value: "training-plan")
                        }
                        if let session = trainingArchive.snapshot.current {
                            trainingProjection(title: "未结束训练", name: session.plan.focus,
                                detail: session.startedAt.formatted(date: .abbreviated, time: .shortened),
                                count: "已登记 \(session.records.count) / \(session.plan.totalSets) 组", id: "current") { trainingSelection = .session(session) }
                                .layoutValue(key: HomeCardIdentity.self, value: "training-current")
                        }
                        ForEach(trainingArchive.snapshot.confirmed) { session in
                            trainingProjection(title: "已确认训练回顾", name: session.plan.focus,
                                detail: (session.confirmedAt ?? session.startedAt).formatted(date: .abbreviated, time: .shortened),
                                count: "完成 \(session.records.filter { $0.status == "completed" }.count) 组 · 部分完成 \(session.records.filter { $0.status == "partial" }.count) 组 · 跳过 \(session.records.filter { $0.status == "skipped" }.count) 组",
                                id: session.id.uuidString) { trainingSelection = .session(session) }
                                .layoutValue(key: HomeCardIdentity.self, value: "training-\(session.id)")
                        }
                        if let error = trainingArchive.error {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(error, systemImage: "exclamationmark.triangle")
                                Button { Task { await trainingArchive.load() } } label: { Label("重试训练档案", systemImage: "arrow.clockwise") }
                                    .accessibilityIdentifier("home-training-retry")
                            }.modifier(HomeCard()).layoutValue(key: HomeCardIdentity.self, value: "training-error")
                        }
                        if let notice = journal.notice {
                            HStack {
                                Text(notice).font(.callout)
                                Spacer()
                                Button { journal.notice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭提示")
                                    .accessibilityIdentifier("journal-dismiss-notice")
                            }.modifier(HomeCard()).layoutValue(key: HomeCardIdentity.self, value: "notice")
                        }
                        ForEach(journal.records) { record in
                            Button { selected = record } label: { recordCard(record) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("journal-record-\(record.id)")
                                .accessibilityHint("查看完整留言和照片")
                                .layoutValue(key: HomeCardIdentity.self, value: record.id.uuidString)
                        }
                        if let error = journal.loadError {
                            VStack(alignment: .leading, spacing: 16) {
                                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                                Button { Task { await journal.load() } } label: { Label("重试读取", systemImage: "arrow.clockwise") }
                                    .accessibilityIdentifier("journal-retry-load")
                            }.modifier(HomeCard())
                        } else if journal.loading {
                            ProgressView("正在读取本机记录").frame(maxWidth: .infinity, minHeight: 80)
                                .modifier(HomeCard()).accessibilityIdentifier("journal-loading")
                        } else if journal.records.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                                Text("还没有生活记录").font(.headline)
                            }.modifier(HomeCard())
                        }
                        if journal.canLoadMore {
                            Button("较早记录") { Task { await journal.load(more: true) } }
                                .accessibilityIdentifier("journal-load-more")
                                .disabled(journal.loading).modifier(HomeCard())
                        }
                    }
                    .padding(16)
                    if trainingDispatcher.pendingRequestID != nil { serviceRecovery.padding(16) }
                    if serviceCards.provider != nil {
                        HomeServiceCardsView(store: serviceCards, onAction: serviceAction).padding(16)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle("Fox")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { editing = false; showingBackup = true } label: { Image(systemName: "externaldrive") }
                        .accessibilityLabel("备份与恢复").accessibilityIdentifier("journal-backup").help("备份与恢复")
                        .disabled(journal.busy || photos.loading)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { editing = false }
                }
            }
            .task { if automaticallyLoad { await journal.load() }; await trainingArchive.load() }
            .fullScreenCover(item: $servicePresentation, onDismiss: {
                _ = trainingDispatcher.dismiss()
                Task { await trainingArchive.load() }
            }) { presentation in
                FoxRootView(store: presentation.store, initialTab: "training", onClose: { servicePresentation = nil })
                    .foxReservedSpace().interactiveDismissDisabled()
            }
            .fullScreenCover(item: $trainingRoute, onDismiss: { Task { await trainingArchive.load() } }) { route in
                FoxRootView(entry: route, onClose: { trainingRoute = nil }).foxReservedSpace().interactiveDismissDisabled()
            }
            .sheet(isPresented: $showingHistory) { HomeTrainingHistory(snapshot: trainingArchive.snapshot) { showingHistory = false } }
            .sheet(isPresented: $showingCapabilities) {
                NavigationStack {
                    List {
                        ForEach(TrainingActivity.allCases) { activity in
                            Button { showingCapabilities = false; trainingRoute = .prepare(activity, .left, UUID()) } label: {
                                VStack(alignment: .leading) { Text(activity.label); Text(activity.subtitle).font(.caption) }
                            }.accessibilityIdentifier("home-try-\(activity.rawValue)")
                        }
                        Button("手动查看与调整计划") { showingCapabilities = false; trainingRoute = .plan }
                            .accessibilityIdentifier("home-plan")
                    }.navigationTitle("训练动作")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingCapabilities = false } } }
                }
            }
            .sheet(isPresented: $showingBackup) { JournalBackupView(journal: journal) }
            .sheet(item: $trainingSelection) { selection in HomeTrainingDetail(selection: selection) { trainingSelection = nil } }
            .sheet(item: $selected) { record in
                JournalRecordDetail(initial: record, journal: journal, close: { selected = nil })
            }
        }
        .tint(FoxStyle.accent)
    }

    private func columnCount(_ width: CGFloat) -> Int {
        FoxAdaptiveLayout.columns(width: width, phone: UIDevice.current.userInterfaceIdiom == .phone,
            horizontal: horizontalSizeClass, vertical: verticalSizeClass, accessibility: typeSize.isAccessibilitySize)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if typeSize.isAccessibilitySize {
                Label("记一下", systemImage: "square.and.pencil").font(.headline)
                HStack(spacing: 8) { mediaActions; Spacer(minLength: 0); saveButton }
            } else {
                HStack(spacing: 8) {
                    Label("记一下", systemImage: "square.and.pencil").font(.headline)
                    Spacer(minLength: 0)
                    mediaActions
                    saveButton
                }
            }
            TextField("此刻，想留下什么？", text: $journal.note, axis: .vertical)
                .font(.body).lineLimit(1...6).focused($editing)
                .disabled(journal.busy).accessibilityIdentifier("journal-note")
            if !photos.items.isEmpty { JournalPhotoPicker(selection: photos, disabled: journal.busy, showActions: false, showErrors: false) }
            if journal.saving || journal.saved {
                HStack(spacing: 12) {
                if journal.saving {
                    ProgressView().accessibilityLabel("正在保存")
                } else if journal.saved && journal.note.isEmpty && photos.items.isEmpty {
                    Label("已存到本机", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(FoxStyle.accent)
                        .accessibilityIdentifier("journal-saved")
                }
                }
            }
            if let error = photos.error { Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("journal-photo-error") }
            if let error = journal.saveError {
                Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("journal-save-error")
            }
        }.modifier(HomeCard())
    }

    private var saveButton: some View {
        Button {
            editing = false
            Task { if await journal.save(photos: photos.items) { photos.items = [] } }
        } label: { Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)).frame(width: 32, height: 32) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .tint(FoxStyle.green)
            .disabled(!journal.canSave(photos: photos.items) || photos.loading)
            .accessibilityLabel(journal.saveError == nil ? "保存" : "重试保存").help("保存记录")
            .accessibilityIdentifier("journal-save")
    }

    private var mediaActions: some View {
        JournalPhotoPicker(selection: photos, disabled: journal.busy, showPreviews: false, showErrors: false)
    }

    private var training: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("训练").font(.title3.bold())
            if !trainingArchive.loaded { ProgressView("正在读取训练档案") }
            if trainingArchive.loaded && trainingArchive.snapshot.sessions.isEmpty && trainingArchive.snapshot.plan == nil && trainingArchive.error == nil {
                Text("本机暂无训练档案").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(trainingArchive.snapshot.unfinished) { session in
                Button { editing = false; trainingRoute = .open(session) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.entryTitle).font(.headline)
                        Text(session.plan.focus).font(.subheadline)
                        Text(session.startedAt, format: .dateTime.month().day().hour().minute()).font(.caption)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier(TrainingEntry.selector(session))
                    .disabled(trainingDispatcher.pendingRequestID != nil)
            }
            Button("试练一组哑铃弯举") { editing = false; trainingRoute = .prepare(.curl, .left, UUID()) }
                .frame(minHeight: 44).accessibilityIdentifier("home-prepare-curl")
                .disabled(trainingDispatcher.pendingRequestID != nil)
            Button("选择训练动作") { editing = false; showingCapabilities = true }
                .frame(minHeight: 44).accessibilityIdentifier("home-capabilities")
                .disabled(trainingDispatcher.pendingRequestID != nil)
            Button("训练记录") { editing = false; showingHistory = true }
                .frame(minHeight: 44).accessibilityIdentifier("home-history")
        }.modifier(HomeCard()).disabled(!trainingArchive.loaded || trainingArchive.error != nil)
    }

    private func serviceAction(_ card: ServiceCard, _ action: ServiceCardAction, _ request: UUID) async throws {
        if [.prepare, .resume, .review].contains(action.kind) {
            let presentation = try trainingDispatcher.execute(card, action: action, requestID: request)
            serviceRecoveryError = nil
            servicePresentation = presentation
            return
        }
        switch card.target {
        case .session(let id, let attempt):
            guard action.kind == .view else { throw ServiceCardError.invalidCard }
            await trainingArchive.load()
            guard let session = trainingArchive.snapshot.sessions.first(where: { $0.id == id }),
                  attempt == nil || session.currentSetAttemptId == attempt || session.records.contains(where: { $0.id == attempt }) else {
                throw ServiceCardError.invalidCard
            }
            trainingSelection = .session(session)
        case .history:
            guard action.kind == .view else { throw ServiceCardError.invalidCard }
            showingHistory = true
        default: throw ServiceCardError.invalidCard
        }
    }

    private var serviceRecovery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("上次切换尚未保存").font(.headline)
            Text("原训练与输入仍保留，采集已暂停。此处重试原操作，不受原卡片是否仍展示影响。")
            if let serviceRecoveryError { Text(serviceRecoveryError).foregroundStyle(.red) }
            Button("重试上次切换") {
                do {
                    let presentation = try trainingDispatcher.retryPending()
                    serviceCards.acknowledgeLocal(requestID: presentation.id)
                    serviceRecoveryError = nil; servicePresentation = presentation
                } catch { serviceRecoveryError = error.localizedDescription }
            }.accessibilityIdentifier("home-retry-training-switch")
        }.modifier(HomeCard())
    }

    private func trainingProjection(title: String, name: String, detail: String, count: String, id: String, action: @escaping () -> Void) -> some View {
        Button { editing = false; action() } label: {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: "figure.strengthtraining.traditional").font(.caption.weight(.medium)).foregroundStyle(FoxStyle.accent)
                Text(name).font(.title3.bold()).multilineTextAlignment(.leading)
                Text(count).font(.body)
                HStack(alignment: .firstTextBaseline) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }.modifier(HomeCard())
        }.buttonStyle(.plain).accessibilityIdentifier("home-training-projection-\(id)")
    }

    private func recordCard(_ record: CaptureRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("生活记录", systemImage: "text.alignleft").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let photo = record.photos.first {
                JournalStoredPhoto(id: photo.id, journal: journal, summary: true)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let note = record.note { Text(note).font(.body).lineLimit(8).multilineTextAlignment(.leading) }
            if record.photos.count > 1 { Text("\(record.photos.count) 张照片").font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .firstTextBaseline) {
                Text(record.recordedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Label("详情", systemImage: "chevron.right").font(.caption).foregroundStyle(FoxStyle.accent)
            }
        }.modifier(HomeCard())
    }
}
