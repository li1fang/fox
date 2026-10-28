import FoxTrainingCore
import SwiftUI

@MainActor
final class HomeServiceCardStore: ObservableObject {
    @Published private(set) var consumer: ServiceCardConsumer
    @Published private(set) var now: Date
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var sending: Set<UUID> = []
    @Published private(set) var localBusy: Set<String> = []
    @Published private(set) var localErrors: [String: String] = [:]
    @Published private(set) var choiceEditing: Set<ServiceCardKey> = []
    @Published private(set) var presentationTime: Date
    let provider: (any ServiceCardProvider)?
    private let clock: () -> Date
    private var focused: ServiceCardKey?
    private var localRequests: [String: UUID] = [:]

    // No production provider is installed implicitly. Synthetic data must be explicitly injected.
    init(provider: (any ServiceCardProvider)? = nil, now: @escaping () -> Date = { Date() }) {
        let initialTime = now()
        self.provider = provider; self.clock = now; self.now = initialTime
        self.presentationTime = initialTime
        var consumer = ServiceCardConsumer(providerID: provider?.providerID ?? "unconfigured")
        // Reading has no reliable focus callback. Hold after the initial snapshot until the
        // user explicitly applies updates; expiry/withdrawal still use the latest snapshot.
        consumer.setReading(true)
        self.consumer = consumer
    }
    var isSynthetic: Bool { provider?.isSynthetic == true }
    var cards: [ServiceCard] {
        (consumer.appliedFeed?.cards ?? []).filter { $0.visible && presentationTime >= $0.visibleFrom }
    }
    var hasPendingUpdates: Bool {
        consumer.pendingFeed != nil || (consumer.appliedFeed?.cards.contains {
            $0.visible && $0.visibleFrom > presentationTime && $0.visibleFrom <= now
        } ?? false)
    }
    var retainedDraftKeys: [ServiceCardKey] {
        let visible = Set(cards.map { key($0) })
        return consumer.drafts.keys.filter { !visible.contains($0) && !(consumer.drafts[$0] ?? "").isEmpty }
            .sorted { ($0.cardID, $0.revision) < ($1.cardID, $1.revision) }
    }
    func key(_ card: ServiceCard) -> ServiceCardKey { card.key(providerID: consumer.providerID) }
    func availability(_ card: ServiceCard) -> ServiceCardAvailability { consumer.availability(of: key(card), at: now) }
    func draft(_ card: ServiceCard) -> String { consumer.drafts[key(card)] ?? "" }
    func setDraft(_ text: String, card: ServiceCard) { consumer.setDraft(text, for: key(card)) }
    func focus(_ key: ServiceCardKey?) {
        // Insert the next focus before removing the previous one so a field-to-field move
        // cannot momentarily apply a pending reorder under the keyboard.
        if let key { consumer.setEditing(true, key: key) }
        if let old = focused, old != key { consumer.setEditing(choiceEditing.contains(old), key: old) }
        focused = key
    }
    func isChoiceEditing(_ card: ServiceCard) -> Bool { choiceEditing.contains(key(card)) }
    func beginChoiceEditing(_ card: ServiceCard) {
        guard case .choice = card.answerSpec, consumer.card(for: key(card)) != nil else { return }
        choiceEditing.insert(key(card)); consumer.setEditing(true, key: key(card))
    }
    func endChoiceEditing(_ card: ServiceCard) {
        choiceEditing.remove(key(card)); consumer.setEditing(focused == key(card), key: key(card))
    }
    @discardableResult
    func applyPendingUpdates() -> Bool {
        guard consumer.editing.isEmpty else { return false }
        // This synchronous boundary applies only content already received. A later fetch
        // remains pending instead of borrowing permission from an earlier button press.
        consumer.setReading(false); consumer.setReading(true)
        tick(); presentationTime = now
        return true
    }
    func tick() { now = clock() }
    func refresh() async {
        guard !loading, let provider else { return }
        loading = true; defer { loading = false }
        do {
            let firstSnapshot = consumer.appliedFeed == nil
            try consumer.receive(await provider.fetchFeed()); error = nil; tick()
            if firstSnapshot { presentationTime = now }
        }
        catch { self.error = "暂时无法更新卡片，已输入内容仍保留。" }
    }
    func input(card: ServiceCard, action: ServiceCardAction) -> ServiceCardInput {
        if action.kind == .edit { return .edit(draft(card)) }
        if action.kind == .answer {
            if case .choice = card.answerSpec { return .answer(.choice(draft(card))) }
            return .answer(.text(draft(card)))
        }
        return .none
    }
    func canSubmit(card: ServiceCard, action: ServiceCardAction) -> Bool {
        guard availability(card) == .available, provider != nil else { return false }
        return (try? card.validate(input: input(card: card, action: action), action: action)) != nil
    }
    func states(for card: ServiceCard) -> [ServiceCardSubmissionState] {
        consumer.submissions.values.filter { $0.submission.key == key(card) }
            .sorted { $0.submission.id.uuidString < $1.submission.id.uuidString }
    }
    func submit(card: ServiceCard, action: ServiceCardAction) async {
        tick()
        do {
            let submission = try consumer.beginSubmission(key: key(card), actionID: action.id,
                input: input(card: card, action: action), at: now)
            if let receipt = consumer.submissions[submission.id]?.receipt, receipt.outcome != .retryableFailure { return }
            await deliver(submission)
        } catch { self.error = "这张卡片暂不能提交，输入仍保留。请核对最新卡片。" }
    }
    func retry(_ id: UUID) async {
        guard let submission = consumer.submissions[id]?.submission else { return }
        // Reconcile even if the card has since expired or disappeared. This is the old immutable
        // submission, never a new answer to an expired/revised question.
        await deliver(submission)
    }
    private func deliver(_ submission: ServiceCardSubmission) async {
        guard let provider, !sending.contains(submission.id) else { return }
        if let receipt = consumer.submissions[submission.id]?.receipt, receipt.outcome != .retryableFailure { return }
        sending.insert(submission.id); consumer.markAwaitingReceipt(submission.id)
        defer { sending.remove(submission.id) }
        do {
            if let receipt = try await provider.query(submission.id) {
                try consumer.receive(receipt)
                if receipt.outcome != .retryableFailure { error = nil; return }
            }
            try consumer.receive(await provider.submit(submission)); error = nil
        } catch { error = "暂未取得接收回执，原提交仍保留，可重试核对。" }
    }
    func localKey(card: ServiceCard, action: ServiceCardAction) -> String {
        "\(consumer.providerID)/\(card.id)/\(card.revision)/\(action.id)"
    }
    func performLocal(card: ServiceCard, action: ServiceCardAction,
                      execute: (ServiceCard, ServiceCardAction, UUID) async throws -> Void) async {
        let identity = localKey(card: card, action: action)
        guard !localBusy.contains(identity) else { return }
        do {
            tick()
            let (current, permitted) = try consumer.action(key: key(card), actionID: action.id, at: now)
            guard permitted.kind.isLocal else { throw ServiceCardError.invalidCard }
            let requestID = localRequests[identity] ?? UUID()
            localRequests[identity] = requestID; localBusy.insert(identity)
            defer { localBusy.remove(identity) }
            try await execute(current, permitted, requestID)
            localErrors[identity] = nil
        } catch { localErrors[identity] = "操作未完成，请重试。原有训练保留。" }
    }
}

@MainActor
struct HomeServiceCardsView: View {
    @ObservedObject var store: HomeServiceCardStore
    // The owner revalidates exact session/activity and executes its own idempotent command.
    // Receiving a card never executes this closure.
    var onAction: (ServiceCard, ServiceCardAction, UUID) async throws -> Void
    @FocusState private var focused: ServiceCardKey?
    @State private var correcting: Set<ServiceCardKey> = []
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.provider != nil {
                HStack {
                    Text("问题与建议").font(.headline)
                    Spacer()
                    Button("检查更新") { Task { await store.refresh() } }
                        .frame(minHeight: 44).disabled(store.loading)
                        .accessibilityIdentifier("home-service-refresh")
                }
            }
            if store.isSynthetic {
                Text("合成服务卡片样本 · 不连接真实服务").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-service-synthetic")
            }
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("home-service-error") }
            if store.provider != nil {
                Text("阅读期间保持卡片顺序。").font(.caption).foregroundStyle(.secondary)
                if store.hasPendingUpdates {
                    Text("有新的卡片，完成输入和查看后可更新。").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("home-service-pending")
                    Button("完成查看并更新") { store.applyPendingUpdates() }
                        .frame(minHeight: 44).disabled(!store.consumer.editing.isEmpty)
                        .accessibilityIdentifier("home-service-apply-updates")
                }
            }
            if store.loading { ProgressView("正在读取卡片") }
            if store.cards.isEmpty && !store.loading { Text("当前暂无服务卡片").foregroundStyle(.secondary).accessibilityIdentifier("home-service-empty") }
            // A single source-order stack keeps service order independent of card height.
            ForEach(store.cards, id: \.id) { card in cardView(card).id(store.key(card)) }
            ForEach(store.retainedDraftKeys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 8) {
                    Text("保留的输入 · \(store.consumer.card(for: key)?.title ?? "原卡片")").font(.headline)
                    Text("原卡片已更新或撤回，输入未提交到新问题。").font(.caption).foregroundStyle(.secondary)
                    Text(store.consumer.drafts[key] ?? "").textSelection(.enabled)
                    submissionRows(key: key)
                }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            // Unresolved submissions remain reachable even when a withdrawn card had no text draft.
            ForEach(orphanSubmissions, id: \.submission.id) { state in submissionRow(state) }
        }
        .accessibilityIdentifier("home-service-cards")
        .accessibilityValue("applied:\(store.consumer.appliedFeed?.revision ?? 0);pending:\(store.consumer.pendingFeed?.revision ?? 0);reading-held:\(store.consumer.reading)")
        .task { await store.refresh() }
        .onReceive(timer) { _ in store.tick() }
        .onChange(of: focused) { store.focus($0) }
        .onDisappear { store.focus(nil) }
    }

    private var orphanSubmissions: [ServiceCardSubmissionState] {
        let keys = Set(store.cards.map { store.key($0) } + store.retainedDraftKeys)
        return store.consumer.submissions.values.filter { !keys.contains($0.submission.key) }
            .sorted { $0.submission.id.uuidString < $1.submission.id.uuidString }
    }
    private func binding(_ card: ServiceCard) -> Binding<String> {
        Binding(get: { store.draft(card) }, set: { store.setDraft($0, card: card) })
    }
    private func cardView(_ card: ServiceCard) -> some View {
        let key = store.key(card)
        return VStack(alignment: .leading, spacing: 12) {
            Text(card.title).font(.headline)
            if !card.body.isEmpty { Text(card.body).font(.body) }
            if card.kind == .question {
                if case .choice(let options) = card.answerSpec {
                    if store.isChoiceEditing(card) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(options, id: \.self) { option in
                                Button { store.setDraft(option, card: card) } label: {
                                    Label(option, systemImage: store.draft(card) == option ? "largecircle.fill.circle" : "circle")
                                }.frame(minHeight: 44)
                            }
                            Button("完成选择") { store.endChoiceEditing(card) }
                                .frame(minHeight: 44).accessibilityIdentifier("home-card-\(card.id)-choice-done")
                        }.accessibilityIdentifier("home-card-\(card.id)-choice-editor")
                    } else {
                        if !store.draft(card).isEmpty { Text("已选择：\(store.draft(card))") }
                        Button(store.draft(card).isEmpty ? "选择回答" : "修改选择") {
                            focused = nil; store.beginChoiceEditing(card)
                        }.frame(minHeight: 44).accessibilityIdentifier("home-card-\(card.id)-choice-begin")
                    }
                } else {
                    TextField("写下回答（可跳过）", text: binding(card), axis: .vertical)
                        .lineLimit(2...6).focused($focused, equals: key)
                        .accessibilityIdentifier("home-card-\(card.id)-answer")
                }
            }
            if correcting.contains(key) {
                TextField("想怎样调整这条建议？", text: binding(card), axis: .vertical)
                    .lineLimit(2...6).focused($focused, equals: key)
                    .accessibilityIdentifier("home-card-\(card.id)-edit")
            }
            if store.availability(card) != .available {
                Text(availabilityText(store.availability(card))).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(card.actions) { action in
                actionButton(card, action: action)
                if let error = store.localErrors[store.localKey(card: card, action: action)] { Text(error).font(.caption).foregroundStyle(.red) }
            }
            submissionRows(key: key)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
            .accessibilityIdentifier("home-card-\(card.id)")
    }
    private func actionButton(_ card: ServiceCard, action: ServiceCardAction) -> some View {
        let key = store.key(card), isCorrection = action.kind == .edit
        let openingCorrection = isCorrection && !correcting.contains(key)
        return Button(openingCorrection ? action.title : (isCorrection ? "提交更正建议" : action.title)) {
            if openingCorrection { correcting.insert(key); focused = key; return }
            Task {
                if action.kind.isLocal { await store.performLocal(card: card, action: action, execute: onAction) }
                else { await store.submit(card: card, action: action) }
            }
        }
        .frame(minHeight: 44)
        .disabled(store.availability(card) != .available || store.localBusy.contains(store.localKey(card: card, action: action)) ||
            (!action.kind.isLocal && !openingCorrection && !store.canSubmit(card: card, action: action)))
        .accessibilityIdentifier("home-card-\(card.id)-action-\(action.id)")
    }
    private func submissionRows(key: ServiceCardKey) -> some View {
        ForEach(store.consumer.submissions.values.filter { $0.submission.key == key }.sorted { $0.submission.id.uuidString < $1.submission.id.uuidString }, id: \.submission.id) { state in
            submissionRow(state)
        }
    }
    private func submissionRow(_ state: ServiceCardSubmissionState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.sending.contains(state.submission.id) { ProgressView("正在核对接收结果") }
            else {
                switch state.receipt?.outcome {
                case .accepted: Text("已接收").foregroundStyle(.secondary)
                case .rejected(let reason): Text("未接收：\(rejectionText(reason))").foregroundStyle(.secondary)
                case .retryableFailure, nil:
                    Text("尚未确认接收，原提交已保留。").foregroundStyle(.secondary)
                    Button("重试核对") { Task { await store.retry(state.submission.id) } }.frame(minHeight: 44)
                }
            }
        }.font(.caption).accessibilityIdentifier("home-submission-\(state.submission.id)")
    }
    private func availabilityText(_ availability: ServiceCardAvailability) -> String {
        switch availability {
        case .available: return ""
        case .notYetVisible: return "暂未开放"
        case .expired: return "已到期，输入仍保留。"
        case .withdrawn: return "已撤回，输入仍保留。"
        case .stale: return "已有新版，原输入仍保留。"
        }
    }
    private func rejectionText(_ reason: ServiceCardRejection) -> String {
        switch reason {
        case .stale: return "卡片已有新版"
        case .expired: return "卡片已到期"
        case .invalid: return "回答不符合要求"
        case .conflict: return "提交内容发生冲突"
        case .unavailable: return "卡片暂不可用"
        }
    }
}
