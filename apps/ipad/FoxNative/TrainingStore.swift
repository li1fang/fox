import Foundation
import FoxTrainingCore
import SwiftUI

@MainActor
final class TrainingStore: ObservableObject {
    private static var testResetConsumed = false
    @Published private(set) var archive = TrainingArchive()
    @Published var errorMessage: String?
    @Published private(set) var storageUnavailable = false
    @Published private var clientStates: [UUID: TrainingClientState] = [:]
    @Published private(set) var executionGeneration = UUID()
    @Published private(set) var executionBlocked = false
    private var pendingSwitch: (command: TrainingSessionCommand, originalCommand: TrainingSessionCommand, cutoff: Date, snapshot: TrainingSwitchSnapshot?, revision: Int)?
    var clientState: TrainingClientState { session.map { clientStates[$0.id] ?? $0.clientState ?? TrainingClientState() } ?? TrainingClientState() }
    var nextPractice: TrainingActivity? {
        get { clientState.nextActivity.flatMap(TrainingActivity.init(rawValue:)) }
        set { guard let token = executionToken else { return }; var state = clientState; state.nextActivity = newValue?.rawValue; setClientState(state, token: token) }
    }
    var executionToken: TrainingExecutionToken? {
        archive.currentSession.map { .init(sessionID: $0.id, attemptID: $0.currentSetAttemptId, generation: executionGeneration) }
    }
    func accepts(_ token: TrainingExecutionToken?) -> Bool { token != nil && token == executionToken && !executionBlocked }
    func setClientState(_ state: TrainingClientState, token: TrainingExecutionToken) {
        guard accepts(token) else { return }; clientStates[token.sessionID] = state
    }
    func stopPresentation(token: TrainingExecutionToken?) {
        guard accepts(token) else { return }; guidance.stop(); workoutVision.stop(token: token)
    }
    @discardableResult
    func saveClientState() -> Bool {
        guard let session, !executionBlocked, clientState != session.clientState else { return !executionBlocked }
        return updateSession { _ in }
    }
    private var repository: LocalTrainingRepository?
    let fileURL: URL
    private let diagnosticRoot: URL?
    private let preferences: UserDefaults?
    @Published private var manualSessionID: String?
    private var preferenceKey: String { "FoxTraining.manual.\(fileURL.path)" }
    var visionRequested: Bool { !clientState.manual }
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

    var session: TrainingSession? { pendingSwitch?.snapshot?.session ?? archive.currentSession }

    static var defaultArchiveURL: URL {
        let testing = ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fox", isDirectory: true)
            .appendingPathComponent(testing ? "ui-test-records.json" : "training-records.v1.json")
    }

    init(archiveURL: URL? = nil, diagnosticRoot: URL? = nil, preferences: UserDefaults? = nil, writer: ((Data, URL) throws -> Void)? = nil) {
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
            if let writer {
                repository = try LocalTrainingRepository(fileURL: fileURL, writer: writer)
            } else if testing && (environment["FOX_UI_FAIL_EARLY_END_ONCE"] == "1" || environment["FOX_UI_FAIL_CONFIRM_ONCE"] == "1" || environment["FOX_UI_FAIL_SWITCH_ONCE"] == "1") {
                var failed = false
                repository = try LocalTrainingRepository(fileURL: fileURL, writer: { data, url in
                    let archive = try LocalTrainingRepository.decoder().decode(TrainingArchive.self, from: data)
                    let blockedWrite = environment["FOX_UI_FAIL_SWITCH_ONCE"] == "1" ? !(archive.commandReceipts ?? []).isEmpty : environment["FOX_UI_FAIL_CONFIRM_ONCE"] == "1"
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
            for session in archive.sessions {
                var state = session.clientState ?? TrainingClientState()
                if session.clientState == nil { state.manual = manualSessionID == session.id.uuidString }
                clientStates[session.id] = state
            }
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
        guard !executionBlocked else {
            errorMessage = "上次切换尚未保存，请先重试切换。"; return false
        }
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
    func updateSession(token: TrainingExecutionToken? = nil, clearErrorOnSuccess: Bool = true, _ action: (inout TrainingSession) throws -> Void) -> Bool {
        guard let owner = token ?? executionToken, accepts(owner) else { return false }
        let inputs = clientState
        return perform(clearErrorOnSuccess: clearErrorOnSuccess) { repository in
            try repository.updateSession(id: owner.sessionID) {
                $0.clientState = inputs
                try action(&$0)
            }
        }
    }

    @discardableResult
    func preparePractice(_ activity: TrainingActivity, arm: ArmSide = .left, requestID: UUID) -> Bool {
        transition(.init(id: requestID, target: .new(TrainingCapabilities.trial(activity, arm: arm))))
    }

    @discardableResult
    func activateSession(_ id: UUID, requestID: UUID) -> Bool {
        transition(.init(id: requestID, target: .existing(id)))
    }

    @discardableResult
    func retrySwitch() -> Bool {
        guard let pendingSwitch else { return false }
        return transition(pendingSwitch.originalCommand)
    }

    private func transition(_ command: TrainingSessionCommand) -> Bool {
        guard let repository else { return false }
        if let pendingSwitch, pendingSwitch.originalCommand != command {
            errorMessage = "上次切换尚未保存，请重试原操作。"; return false
        }
        do {
            if pendingSwitch == nil {
                var executionCommand = command
                if let receipt = archive.commandReceipts?.first(where: { $0.command.id == command.id }) {
                    guard receipt.command == command,
                          archive.sessions.contains(where: { $0.id == receipt.sessionID && !$0.isFinished }) else {
                        errorMessage = "原请求对应的训练不可用。"; return false
                    }
                    if archive.currentSession?.id == receipt.sessionID { errorMessage = nil; return true }
                    // The creation receipt identifies A. Opening it again is a new selection of A,
                    // never a second creation and never success while B remains foreground.
                    executionCommand = .init(id: UUID(), target: .existing(receipt.sessionID))
                }
                if case .existing(let id) = executionCommand.target,
                   !archive.sessions.contains(where: { $0.id == id && !$0.isFinished }) {
                    errorMessage = "目标训练不可用。"; return false
                }
                var snapshot = repository.switchSnapshot()
                let inputs = clientState
                let cutoff = session?.currentObservationId == nil ? Date() : workoutVision.controller.wallTime
                var fallback = snapshot
                if fallback != nil {
                    fallback!.session.clientState = inputs
                    let trustedTime = fallback!.session.lastCheckpointAt
                    if fallback!.session.stage == .active { try fallback!.session.pause(at: trustedTime) }
                    else if fallback!.session.currentObservationId != nil { try fallback!.session.cancelVisualPreparation(at: trustedTime) }
                }
                // Freeze before touching the camera. A failed final snapshot retains only the
                // last persisted facts and never leaves the old generation/timer running.
                pendingSwitch = (executionCommand, command, fallback?.session.lastCheckpointAt ?? cutoff, fallback, repository.revision)
                executionBlocked = true
                guidance.stop()
                executionGeneration = UUID()
                if snapshot != nil {
                    snapshot!.session.clientState = inputs
                    try workoutVision.quiesce(&snapshot!.session, at: cutoff)
                }
                pendingSwitch = (executionCommand, command, cutoff, snapshot, repository.revision)
            }
            guard let pending = pendingSwitch else { return false }
            _ = try repository.switchForeground(pending.command, expectedRevision: pending.revision, at: pending.cutoff, preserving: pending.snapshot)
            archive = repository.archive
            pendingSwitch = nil; executionBlocked = false; errorMessage = nil
            if let session { clientStates[session.id] = session.clientState ?? TrainingClientState() }
            return true
        } catch {
            errorMessage = "切换未保存，仍保留原训练；采集已暂停，请重试原操作。\(error.localizedDescription)"
            return false
        }
    }

    func savePlan(_ plan: TrainingPlan) {
        perform { try $0.update { $0.plan = plan } }
    }

    func start() { startNewSession(TrainingCapabilities.prepared(archive.plan)) }

    func startTrial(_ exercise: TrainingActivity = .curl) {
        guard session == nil else { return }
        startNewSession(TrainingCapabilities.trial(exercise))
    }

    private func startNewSession(_ plan: TrainingPlan) {
        perform { repository in
            try repository.update { archive in
                guard archive.currentSession == nil else { throw TrainingError.activeSessionExists }
                let session = try TrainingSession(plan: plan, now: Date())
                archive.sessions.append(session); archive.foregroundSessionID = session.id
            }
        }
    }

    @discardableResult
    func selectActivity(_ activity: TrainingActivity, arm: ArmSide = .left, token: TrainingExecutionToken? = nil) -> Bool {
        if let token, !accepts(token) { return false }
        guard let session else { startTrial(activity); return self.session != nil }
        guard session.canReplaceQuickPractice else {
            nextPractice = activity.exerciseID == session.exercise.exerciseId ? nil : activity
            return true
        }
        guard updateSession({ try $0.replaceQuickPractice(with: TrainingCapabilities.trial(activity, arm: arm), at: Date()) }) else { return false }
        workoutVision.stop()
        var state = clientState; state.manual = false
        if let token = executionToken { setClientState(state, token: token) }
        nextPractice = nil
        workoutVision.preview()
        return true
    }

    // Saving and continuing is one transaction: a failed write keeps the old summary and facts.
    @discardableResult
    func confirmSummary(token: TrainingExecutionToken? = nil, note: String, nextActivity: TrainingActivity? = nil, arm: ArmSide = .left) -> Bool {
        guard accepts(token ?? executionToken) else { return false }
        let saved = perform { repository in
            try repository.update { archive in
                guard let id = self.session?.id, let index = archive.sessions.firstIndex(where: { $0.id == id }), archive.sessions[index].stage == .summary else {
                    throw TrainingError.invalidTransition
                }
                if nextActivity != nil && archive.sessions[index].records.contains(where: { $0.feedback.contains(.pain) }) {
                    throw TrainingError.invalidTransition
                }
                archive.sessions[index].clientState = self.clientState
                try archive.sessions[index].confirm(note: note, at: Date())
                if let nextActivity {
                    let next = try TrainingSession(plan: TrainingCapabilities.trial(nextActivity, arm: arm), now: Date())
                    archive.sessions.append(next); archive.foregroundSessionID = next.id
                }
            }
        }
        if saved {
            guidance.stop(); executionGeneration = UUID()
            workoutVision.stop()
            nextPractice = nil
            if nextActivity != nil {
                manualSessionID = nil
                preferences?.removeObject(forKey: preferenceKey)
            }
        }
        return saved
    }

    func setVisionEnabled(_ enabled: Bool, token: TrainingExecutionToken? = nil) {
        if let token, !accepts(token) { return }
        guard let session, [.ready, .active, .paused].contains(session.stage) else { return }
        if !enabled {
            guard workoutVision.disableVision() else { return }
            var state = clientState; state.manual = true
            if let token = executionToken { setClientState(state, token: token) }
        } else {
            // A manual segment cannot be relabelled as visual. The next set can enable it again.
            guard canEnableVision else { return }
            var state = clientState; state.manual = false
            if let token = executionToken { setClientState(state, token: token) }
            workoutVision.stop()
        }
        _ = saveClientState()
        if enabled { workoutVision.preview() }
    }

    func pauseIfActive(token: TrainingExecutionToken? = nil) {
        guard accepts(token ?? executionToken) else { return }
        if session?.stage == .active { updateSession { try $0.pause(at: Date()) } }
    }

    func checkpoint(token: TrainingExecutionToken? = nil) {
        guard accepts(token ?? executionToken), session?.stage == .active else { return }
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
