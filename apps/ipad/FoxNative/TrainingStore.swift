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
    private let preferences: UserDefaults?
    @Published private var manualSessionID: String?
    private var preferenceKey: String { "FoxTraining.manual.\(fileURL.path)" }
    var visionRequested: Bool { session.map { manualSessionID != $0.id.uuidString } ?? true }
    private var manuallyStartedAttempt: Bool {
        session.map { $0.setStartedAt != nil && $0.currentVisualEvidence == nil } ?? false
    }
    var canEnableVision: Bool {
        guard let session, [.ready, .paused].contains(session.stage), session.exercise.visualObservation != nil else { return false }
        return !manuallyStartedAttempt && session.currentVisualEvidence?.fallbackReason == nil
    }
    var usesVision: Bool {
        guard visionRequested, !manuallyStartedAttempt, let session, session.exercise.visualObservation != nil,
              session.currentVisualEvidence?.fallbackReason == nil else { return false }
        switch workoutVision.controller.cameraState {
        case .denied, .restricted, .unavailable, .failed: return false
        default: return true
        }
    }
    lazy var workoutVision = WorkoutVisionCoordinator(store: self, diagnosticRoot: diagnosticRoot)
    lazy var guidance = GuidanceSession(vision: workoutVision.controller, store: self)

    var session: TrainingSession? { archive.currentSession }

    static var defaultArchiveURL: URL {
        let testing = ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fox", isDirectory: true)
            .appendingPathComponent(testing ? "ui-test-records.json" : "training-records.v1.json")
    }

    init(archiveURL: URL? = nil, diagnosticRoot: URL? = nil, preferences: UserDefaults? = nil) {
        self.diagnosticRoot = diagnosticRoot
        self.preferences = preferences ?? (archiveURL == nil ? .standard : nil)
        let environment = ProcessInfo.processInfo.environment
        let testing = environment["FOX_UI_TESTING"] == "1"
        fileURL = archiveURL ?? Self.defaultArchiveURL
        manualSessionID = self.preferences?.string(forKey: "FoxTraining.manual.\(fileURL.path)")
        if testing && ProcessInfo.processInfo.arguments.contains("--ui-testing-reset") && !Self.testResetConsumed {
            Self.testResetConsumed = true
            try? FileManager.default.removeItem(at: fileURL)
        }
        do {
            let repository: LocalTrainingRepository
            if testing && (environment["FOX_UI_FAIL_EARLY_END_ONCE"] == "1" || environment["FOX_UI_FAIL_CONFIRM_ONCE"] == "1") {
                var failed = false
                repository = try LocalTrainingRepository(fileURL: fileURL, writer: { data, url in
                    let archive = try LocalTrainingRepository.decoder().decode(TrainingArchive.self, from: data)
                    let blockedWrite = environment["FOX_UI_FAIL_CONFIRM_ONCE"] == "1"
                        ? archive.sessions.contains(where: { $0.isFinished })
                        : archive.sessions.contains(where: { $0.endedEarly })
                    if !failed && blockedWrite {
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

    func start() { startNewSession(TrainingCapabilities.prepared(archive.plan)) }

    func startTrial(_ exercise: VisionExercise = .curl) {
        guard session == nil else { return }
        startNewSession(TrainingCapabilities.trial(exercise))
    }

    private func startNewSession(_ plan: TrainingPlan) {
        perform { repository in
            try repository.update { archive in
                guard archive.currentSession == nil else { throw TrainingError.activeSessionExists }
                archive.sessions.append(try TrainingSession(plan: plan, now: Date()))
            }
        }
    }

    func setVisionEnabled(_ enabled: Bool) {
        guard let session, [.ready, .active, .paused].contains(session.stage) else { return }
        if !enabled {
            guard workoutVision.disableVision() else { return }
            manualSessionID = session.id.uuidString
        } else {
            // A manual segment cannot be relabelled as visual. The next set can enable it again.
            guard canEnableVision else { return }
            manualSessionID = nil
            workoutVision.stop()
        }
        preferences?.set(manualSessionID, forKey: preferenceKey)
        if enabled { workoutVision.preview() }
    }

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
