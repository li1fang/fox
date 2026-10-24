import Foundation
import FoxTrainingCore
import SwiftUI

@MainActor
final class TrainingStore: ObservableObject {
    private static var testResetConsumed = false
    @Published private(set) var archive = TrainingArchive()
    @Published var errorMessage: String?
    @Published private(set) var storageUnavailable = false
    private var repository: LocalTrainingRepository?
    let fileURL: URL
    private let diagnosticRoot: URL?
    lazy var workoutVision = WorkoutVisionCoordinator(store: self, diagnosticRoot: diagnosticRoot)
    lazy var guidance = GuidanceSession(vision: workoutVision.controller, store: self)

    var session: TrainingSession? { archive.currentSession }

    static var defaultArchiveURL: URL {
        let testing = ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fox", isDirectory: true)
            .appendingPathComponent(testing ? "ui-test-records.json" : "training-records.v1.json")
    }

    init(archiveURL: URL? = nil, diagnosticRoot: URL? = nil) {
        self.diagnosticRoot = diagnosticRoot
        let environment = ProcessInfo.processInfo.environment
        let testing = environment["FOX_UI_TESTING"] == "1"
        fileURL = archiveURL ?? Self.defaultArchiveURL
        if testing && ProcessInfo.processInfo.arguments.contains("--ui-testing-reset") && !Self.testResetConsumed {
            Self.testResetConsumed = true
            try? FileManager.default.removeItem(at: fileURL)
        }
        do {
            let repository: LocalTrainingRepository
            if testing && environment["FOX_UI_FAIL_EARLY_END_ONCE"] == "1" {
                var failed = false
                repository = try LocalTrainingRepository(fileURL: fileURL, writer: { data, url in
                    let archive = try LocalTrainingRepository.decoder().decode(TrainingArchive.self, from: data)
                    if !failed && archive.sessions.contains(where: { $0.endedEarly }) {
                        failed = true
                        throw CocoaError(.fileWriteOutOfSpace)
                    }
                    try data.write(to: url, options: .atomic)
                })
            } else {
                repository = try LocalTrainingRepository(fileURL: fileURL)
            }
            self.repository = repository
            archive = repository.archive
            if environment["FOX_PREPARE_DAY1_DRAFT"] == "1", archive.plan.focus != "Real exercise · Day 1" {
                prepareDay1Draft()
            }
        } catch {
            errorMessage = error.localizedDescription
            storageUnavailable = true
        }
    }

    @discardableResult
    func perform(clearErrorOnSuccess: Bool = true, _ action: (LocalTrainingRepository) throws -> Void) -> Bool {
        guard let repository else { return false }
        do {
            try action(repository)
            archive = repository.archive
            if clearErrorOnSuccess { errorMessage = nil }
            return true
        } catch {
            errorMessage = "未保存这次操作：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func updateSession(clearErrorOnSuccess: Bool = true, _ action: (inout TrainingSession) throws -> Void) -> Bool {
        perform(clearErrorOnSuccess: clearErrorOnSuccess) { try $0.updateCurrent(action) }
    }

    func savePlan(_ plan: TrainingPlan) {
        perform { try $0.update { $0.plan = plan } }
    }

    func start() { perform { try $0.start(plan: archive.plan, at: Date()) } }

    func pauseIfActive() {
        if session?.stage == .active { updateSession { try $0.pause(at: Date()) } }
    }

    func checkpoint() {
        guard session?.stage == .active else { return }
        if session?.currentObservationId != nil { workoutVision.flush(); return }
        updateSession(clearErrorOnSuccess: false) { $0.checkpoint(at: Date()) }
    }

    func prepareDay1Draft() {
        guard session == nil else { errorMessage = "请先结束当前训练，再更换计划。"; return }
        do { savePlan(try TrainingPlan.realExerciseDay1Draft()) }
        catch { errorMessage = error.localizedDescription }
    }

    func prepareNextTrialDraft() {
        guard session == nil else { errorMessage = "请先结束当前训练，再更换计划。"; return }
        do { savePlan(try TrainingPlan.nextTrainingTrialDraft()) }
        catch { errorMessage = error.localizedDescription }
    }

    func importPlan(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else { throw TrainingError.invalidPlan }
            let plan = try JSONDecoder().decode(TrainingPlan.self, from: Data(contentsOf: url))
            try plan.validate()
            savePlan(plan)
        } catch { errorMessage = "无法导入计划：\(error.localizedDescription)" }
    }

    func export(_ session: TrainingSession) -> URL? {
        struct Export: Encodable {
            let schema = "fox.native_workout.v1"
            let session: TrainingSession
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fox-\(session.id).json")
            try LocalTrainingRepository.encoder().encode(Export(session: session)).write(to: url, options: .atomic)
            return url
        } catch { errorMessage = "导出失败：\(error.localizedDescription)"; return nil }
    }
}
