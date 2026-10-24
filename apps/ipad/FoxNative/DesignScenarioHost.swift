#if DEBUG
import FoxJournalCore
import FoxTrainingCore
import SwiftUI

@MainActor
struct DesignScenarioHost: View {
    let scenario: DesignScenario
    @State private var journal: JournalStore?
    @State private var error: String?
    @State private var training: TrainingStore?
    @State private var diagnosticReview: VisionDiagnosticManifest?
    @StateObject private var photos = JournalPhotoSelection()
    var body: some View {
        Group {
            if let journal {
                destination(journal)
                    .environment(\.journalMediaAccessAllowed, false)
                    .dynamicTypeSize(scenario.usesLargeType ? .accessibility2 : .large)
                    .preferredColorScheme(scenario.usesDarkAppearance ? .dark : .light)
            } else if let error { Text(error).accessibilityIdentifier("design-scenario-error") }
            else { ProgressView("准备设计样本") }
        }
        .safeAreaInset(edge: .bottom) {
            Text("设计样本 · \(scenario.id)").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(4).background(.bar)
                .accessibilityIdentifier(journal == nil ? "design-scenario-preparing" : "design-scenario-ready")
        }
        .task {
            guard journal == nil else { return }
            do {
                let fixture = try DesignFixtures.make(scenario)
                if scenario.section == "training" {
                    let store = try DesignFixtures.training(scenario)
                    if scenario == .trainingDiagnostic {
                        let capture = store.workoutVision.controller.diagnosticCapture
                        let context = VisionDiagnosticContext(source: .fixture, device: "design-fixture", appVersion: "design", appBuild: "design",
                            camera: "front", exercise: .curl, arm: .left, bodyView: .side, screenOrientation: .portrait,
                            configuration: .standard, runtimePolicy: .standard)
                        let folder = try VisionDiagnosticArchive.prepare(context, root: capture.draftRoot)
                        diagnosticReview = try VisionDiagnosticArchive.seal(context: context, folder: folder, state: "failed",
                            reason: "designSampleNoVideo", error: nil, video: nil, automaticCount: 0)
                    }
                    training = store
                }
                await fixture.load()
                if scenario == .keyboard { fixture.note = "设计样本：刚刚吃了午饭，想补充一点记录。" }
                if scenario == .failure {
                    fixture.note = "设计样本：输入保留，保存可以重试。"
                    _ = await fixture.save()
                }
                fixture.presentDesignState(scenario)
                journal = fixture
            } catch { self.error = "设计场景失败：\(error.localizedDescription)" }
        }
    }
    @ViewBuilder private func destination(_ journal: JournalStore) -> some View {
        if let training {
            if let diagnosticReview { DiagnosticReview(capture: training.workoutVision.controller.diagnosticCapture, manifest: diagnosticReview) }
            else { DesignTrainingHost(store: training, scenario: scenario) }
        } else if scenario == .recordBackup { JournalBackupView(journal: journal) }
        else if scenario.section == "records", let record = journal.records.first {
            JournalRecordDetail(initial: record, journal: journal, close: {})
        } else { FoxHomeView(journal: journal, photos: photos,
            trainingArchive: HomeTrainingStore(url: DesignFixtures.root(scenario).appendingPathComponent("training.json")), automaticallyLoad: false) }
    }
}

@MainActor
private struct DesignTrainingHost: View {
    let store: TrainingStore
    @StateObject private var vision: VisionLabController
    init(store: TrainingStore, scenario: DesignScenario) {
        self.store = store
        let root = DesignFixtures.root(scenario)
        _vision = StateObject(wrappedValue: VisionLabController(diagnosticRoot: root.appendingPathComponent("LabDiagnostics"),
            storageDirectory: root.appendingPathComponent("LabVision")))
    }
    var body: some View { FoxRootView(store: store, vision: vision, initialTab: "training", onClose: {}) }
}

@MainActor
enum DesignFixtures {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static func root(_ scenario: DesignScenario) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FoxDesign", isDirectory: true)
            .appendingPathComponent(scenario.id, isDirectory: true)
    }
    static func make(_ scenario: DesignScenario) throws -> JournalStore {
        let root = root(scenario)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Journal"), repository = try LocalJournalRepository(directory: directory)
        let count = scenario == .empty || scenario == .loading || scenario == .failure || scenario == .keyboard ? 0 :
            (scenario == .pagination ? 54 : (scenario == .mixed || scenario == .dark ? 5 : 1))
        for index in 0..<count {
            let text = [.longText, .recordText, .recordMulti].contains(scenario) ? String(repeating: "设计样本：今天的生活记录包含比较长的留言，需要查看全文而不是丢失最后一句。", count: 14) + "正文结束。" :
                ["设计样本：午饭，想记下这一餐。", "设计样本：散步后精神不错，今天先不做分析。", "设计样本：买了两份食材，价格和重量稍后补充。"][index % 3]
            let data = scenario == .recordMulti ? [DesignScenario.portrait, .receipt, .landscape].map { PhotoInput(data: image($0), mimeType: "image/png") } :
                (scenario.hasPhoto && index == 0 ? [PhotoInput(data: image(scenario), mimeType: "image/png")] : [])
            let id = UUID(uuidString: String(format: "12340000-0000-4000-8000-%012d", index + 1))!
            let record = try repository.record(CaptureDraft(id: id, recordedAt: date.addingTimeInterval(-Double(index) * 3600),
                timeZoneIdentifier: "Asia/Bangkok", note: text, photos: data))
            if [.missing, .recordMissing].contains(scenario), let photo = record.photos.first {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(photo.relativePath))
            }
        }
        let trainingURL = root.appendingPathComponent("training.json")
        if scenario == .homeCorruptTraining { try Data("invalid design archive".utf8).write(to: trainingURL) }
        else if [.homePlan, .homeCurrent, .homeConfirmed].contains(scenario) {
            var archive = TrainingArchive()
            archive.plan.focus = "设计样本：一个较长名称的本机哑铃训练计划"
            if scenario == .homeCurrent {
                var session = try TrainingSession(plan: archive.plan, now: date)
                try session.startSet(at: date)
                archive.sessions = [session]
            } else if scenario == .homeConfirmed {
                var session = try TrainingSession(plan: archive.plan, now: date)
                try session.startSet(at: date); try session.finishSet(at: date.addingTimeInterval(30))
                try session.submit(reps: 8, feedback: [.comfortable], notes: "设计样本：人工确认，不是自动次数。", at: date.addingTimeInterval(31))
                try session.endEarly(at: date.addingTimeInterval(60)); try session.confirm(note: "设计样本：提前结束。", at: date.addingTimeInterval(61))
                archive.sessions = [session]
            }
            try archive.validate()
            try LocalTrainingRepository.encoder().encode(archive).write(to: trainingURL)
        }
        return JournalStore(directory: directory, exportDirectory: root.appendingPathComponent("Exports"),
            failSaveOnce: scenario == .failure, conflictOnce: scenario == .recordConflict)
    }
    static func image(_ scenario: DesignScenario) -> Data {
        let size: CGSize = scenario == .portrait ? CGSize(width: 480, height: 800) :
            ([.receipt, .recordLongPhoto].contains(scenario) ? CGSize(width: 480, height: 2200) : CGSize(width: 800, height: 480))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(red: 0.91, green: 0.96, blue: 0.93, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 30, y: 100, width: size.width - 60, height: 80))
            let title = "设计样本  PHOTO" as NSString
            title.draw(at: CGPoint(x: 30, y: 25), withAttributes: [.font: UIFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: UIColor.black])
            for index in 0..<Int(size.height / 90) - 2 {
                let text = "\(index + 1). SAMPLE  125.00  /  500 g" as NSString
                text.draw(at: CGPoint(x: 30, y: 220 + index * 80), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 23, weight: .regular), .foregroundColor: UIColor.black])
            }
        }
    }
    static func training(_ scenario: DesignScenario) throws -> TrainingStore {
        let directory = root(scenario)
        var archive = TrainingArchive()
        if scenario == .trainingWaiting || scenario == .trainingFeedbackRotated { archive.plan = try TrainingPlan.realExerciseDay1Draft() }
        try LocalTrainingRepository.encoder().encode(archive).write(to: directory.appendingPathComponent("training.json"))
        let store = TrainingStore(archiveURL: directory.appendingPathComponent("training.json"), diagnosticRoot: directory.appendingPathComponent("Diagnostics"))
        store.start()
        let now = Date()
        if [.trainingActive, .trainingRotated, .trainingLargeType, .trainingPaused, .trainingRest, .trainingFeedback, .trainingFeedbackRotated, .trainingSummary].contains(scenario) {
            guard store.updateSession({ try $0.startSet(at: now.addingTimeInterval(-25)) }) else { throw TrainingError.invalidTransition }
        }
        if scenario == .trainingPaused { _ = store.updateSession { try $0.pause(at: now) } }
        if [.trainingRest, .trainingFeedback, .trainingFeedbackRotated, .trainingSummary].contains(scenario) {
            _ = store.updateSession { try $0.finishSet(at: now) }
            if scenario != .trainingFeedback && scenario != .trainingFeedbackRotated {
                _ = store.updateSession { try $0.submit(reps: 8, feedback: [.comfortable], notes: "设计样本", at: now) }
            }
            if scenario == .trainingSummary { _ = store.updateSession { try $0.endEarly(at: now) } }
        }
        if scenario == .trainingWaiting {
            guard store.workoutVision.controller.fixtureMode != nil else { throw TrainingError.invalidTransition }
            store.workoutVision.prepare(arm: .left)
        }
        return store
    }
}

struct FoxHomeDesignPreviews: PreviewProvider {
    static var previews: some View {
        DesignScenarioHost(scenario: .mixed).previewDisplayName("Home · 混合内容")
        DesignScenarioHost(scenario: .receipt).previewDisplayName("Home · 长图")
    }
}
#endif
