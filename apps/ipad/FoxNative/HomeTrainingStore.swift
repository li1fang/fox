import Foundation
import FoxTrainingCore
import SwiftUI

struct HomeTrainingSnapshot: Equatable {
    var plan: TrainingPlan?
    var current: TrainingSession?
    var confirmed: [TrainingSession] = []

    // Do not construct LocalTrainingRepository here: its recovery path can persist a paused session.
    static func read(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw TrainingError.corruptArchive }
        let archive = try LocalTrainingRepository.decoder().decode(TrainingArchive.self, from: Data(contentsOf: url))
        try archive.validate()
        return Self(plan: archive.plan, current: archive.currentSession,
            confirmed: Array(archive.sessions.filter(\.isFinished).sorted {
                ($0.confirmedAt ?? $0.startedAt) > ($1.confirmedAt ?? $1.startedAt)
            }.prefix(2)))
    }
}

@MainActor
final class HomeTrainingStore: ObservableObject {
    @Published private(set) var snapshot = HomeTrainingSnapshot()
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    private let url: URL
    private var generation = UUID()
    init(url: URL? = nil) { self.url = url ?? TrainingStore.defaultArchiveURL }
    func load() async {
        let token = UUID(); generation = token; loaded = false
        let path = url
        let result = await Task.detached { Result { try HomeTrainingSnapshot.read(from: path) } }.value
        guard generation == token, !Task.isCancelled else { return }
        switch result {
        case .success(let value): snapshot = value; error = nil
        case .failure: snapshot = HomeTrainingSnapshot(); error = "本机训练档案暂时无法读取。原文件未更改。"
        }
        loaded = true
    }
}

enum HomeTrainingSelection: Identifiable {
    case plan(TrainingPlan), session(TrainingSession)
    var id: String {
        switch self { case .plan: return "plan"; case .session(let session): return session.id.uuidString }
    }
}

struct HomeTrainingDetail: View {
    let selection: HomeTrainingSelection
    let close: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("本机档案 · 只读", systemImage: "internaldrive").font(.subheadline).foregroundStyle(.secondary)
                    switch selection {
                    case .plan(let plan):
                        Text(plan.focus).font(.title.bold())
                        Text(plan.scheduledDate.map { "计划日期：\($0) · \(plan.scheduledTimeZone ?? "")" } ?? "未安排日期 · 开始前确认")
                            .foregroundStyle(.secondary)
                        TrainingPlanOverview(plan: plan)
                    case .session(let session):
                        Text(session.plan.focus).font(.title.bold())
                        Text(session.isFinished ? "已确认训练回顾" : "未结束训练 · 进入训练后继续")
                            .font(.headline).foregroundStyle(FoxStyle.accent)
                        Text(session.startedAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
                        SessionSummary(session: session)
                    }
                }.padding(24).frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("home-training-detail")
            .navigationTitle("训练档案").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成", action: close) } }
        }
    }
}

struct TrainingPlanOverview: View {
    let plan: TrainingPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(plan.warmup).foregroundStyle(.secondary)
            ForEach(plan.exercises) { exercise in
                VStack(alignment: .leading, spacing: 12) {
                    Text(exercise.name).font(.title3.bold())
                    ForEach(exercise.targetSets.indices, id: \.self) { index in
                        let target = exercise.targetSets[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(target.setIndex) 组 · \(target.targetReps.map { "\($0) 次\(exercise.repetitionBasis == .perSide ? " / 侧" : "")" } ?? durationText(target.targetDurationSeconds ?? 0))")
                                .font(.body.weight(.medium))
                            Text("\(weightText(target.targetWeight, unit: target.weightUnit)) · 休息 \(Int(target.restSeconds)) 秒")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.monospacedDigit()
                    }
                    if let notes = exercise.notes, !notes.isEmpty { Text(notes).font(.callout).foregroundStyle(.secondary) }
                }
                Divider()
            }
            Text(plan.cooldown).foregroundStyle(.secondary)
            Text(plan.safetyNotes).font(.callout).foregroundStyle(.secondary)
        }
    }
}
