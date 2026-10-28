import FoxTrainingCore
import Foundation

@MainActor
final class WorkoutVisionCoordinator {
    let controller: VisionLabController
    private weak var store: TrainingStore?
    private var binding: WorkoutSetBinding?
    private var observationId: UUID?
    private var lastPersistedAt = 0.0
    private var lastCount = 0
    private var stopping = false

    init(store: TrainingStore, diagnosticRoot: URL? = nil) {
        controller = VisionLabController(diagnosticRoot: diagnosticRoot ?? VisionDiagnosticArchive.root,
            storageDirectory: diagnosticRoot?.deletingLastPathComponent().appendingPathComponent("WorkoutVision"))
        self.store = store
        installCallbacks(token: nil, observation: nil, target: nil)
    }

    private func installCallbacks(token: TrainingExecutionToken?, observation: UUID?, target: WorkoutSetBinding?) {
        controller.onCameraStateChanged = { [weak self] state in
            guard let self, self.store?.accepts(token) == true, self.observationId == observation,
                  observation != nil, state == .running else { return }
            self.controller.startCounting()
        }
        controller.onCountingBegan = { [weak self] in
            guard let self, let store = self.store, store.accepts(token), let observation,
                  self.observationId == observation, store.session?.currentSetBinding == target else { return false }
            return store.updateSession(token: token) { try $0.beginVisual(observationId: observation, at: self.controller.wallTime) }
        }
        controller.onCountingUpdated = { [weak self] in
            guard let self, self.store?.accepts(token) == true, self.observationId == observation else { return }
            let now = self.controller.uptime
            if now - self.lastPersistedAt >= 2 || self.lastCount != self.controller.automaticCount { _ = self.flush(token: token) }
        }
        controller.onCountingPaused = { [weak self] in
            guard let self, !self.stopping, self.store?.accepts(token) == true,
                  self.observationId == observation else { return }
            _ = self.pause(token: token)
        }
    }

    func prepare(arm: ArmSide, token: TrainingExecutionToken? = nil) {
        if let token, store?.accepts(token) != true { return }
        guard let store, let session = store.session, var settings = session.exercise.visualObservation else { return }
        if let evidence = session.currentVisualEvidence { settings = evidence.settings } else { settings.arm = arm }
        let configuration = session.currentVisualEvidence?.configuration ?? controller.configuration
        let policy = session.currentVisualEvidence?.runtimePolicy ?? controller.runtimePolicy
        var id: UUID?
        guard store.updateSession({ id = try $0.prepareVisual(settings: settings, configuration: configuration,
            runtimePolicy: policy, source: controller.source, at: controller.wallTime) }), let id else { return }
        stopping = true
        do { try controller.configureWorkout(settings: settings, configuration: configuration, runtimePolicy: policy) }
        catch {
            stopping = false
            _ = store.updateSession { try $0.cancelVisualPreparation(at: controller.wallTime) }
            store.errorMessage = error.localizedDescription
            return
        }
        stopping = false; binding = store.session?.currentSetBinding; observationId = id
        installCallbacks(token: store.executionToken, observation: id, target: binding)
        controller.diagnosticWorkoutSessionID = session.id
        controller.diagnosticSetAttemptID = session.currentSetAttemptId
        lastPersistedAt = 0; lastCount = 0
        controller.beginTemporaryDiagnostic()
        controller.startCamera()
    }

    // Preview is not an armed start and does not create observation or recording facts.
    func preview(token: TrainingExecutionToken? = nil) {
        if let token, store?.accepts(token) != true { return }
        guard let store, store.usesVision, let session = store.session,
              [.ready, .paused].contains(session.stage), session.currentObservationId == nil else { return }
        if controller.cameraState == .stopped { controller.startCamera() }
    }

    func stopUnarmedPreview(token: TrainingExecutionToken? = nil) {
        if let token, store?.accepts(token) != true { return }
        guard store?.session?.currentObservationId == nil else { return }
        stop()
    }

    @discardableResult
    func disableVision(token: TrainingExecutionToken? = nil) -> Bool {
        if let token, store?.accepts(token) != true { return false }
        guard let store, flush() else { return false }
        if store.session?.currentVisualEvidence != nil {
            guard store.updateSession({ try $0.useManualCounting(reason: .userChoice, at: controller.wallTime) }) else { return false }
        }
        stop()
        return true
    }

    @discardableResult
    func flush(token: TrainingExecutionToken? = nil) -> Bool {
        if let token, store?.accepts(token) != true { return false }
        guard let store, let binding, let id = observationId,
              store.session?.stage == .active, store.session?.currentObservationId == id,
              store.session?.currentSetBinding == binding else { return true }
        let saved = store.updateSession(clearErrorOnSuccess: false) {
            try $0.updateVisual(binding: binding, observationId: id, repetitions: controller.repetitions,
                attempts: controller.attempts, droppedAttempts: controller.droppedAttempts, metrics: controller.metrics,
                resetCounts: controller.diagnostics.resetCounts, captureContext: controller.captureContext, at: controller.wallTime)
        }
        if saved { lastPersistedAt = controller.uptime; lastCount = controller.automaticCount }
        else { stopping = true; controller.pauseCounting(); stopping = false }
        return saved
    }

    @discardableResult
    func pause(token: TrainingExecutionToken? = nil) -> Bool {
        if let token, store?.accepts(token) != true { return false }
        stopping = true; controller.pauseCounting(); stopping = false
        guard let store, flush() else { return false }
        let saved = store.updateSession {
            if $0.stage == .active { try $0.pause(at: controller.wallTime) }
            else if $0.currentObservationId != nil { try $0.cancelVisualPreparation(at: controller.wallTime) }
        }
        if saved { controller.finishDiagnostic(reason: "preparationCancelledOrPaused"); stop() }
        return saved
    }

    func rebindSubject(token: TrainingExecutionToken? = nil) {
        if let token, store?.accepts(token) != true { return }
        guard controller.needsRebind else { return }
        let side = controller.arm
        guard pause() else { return }
        prepare(arm: side)
    }

    func finish(token: TrainingExecutionToken? = nil) {
        if let token, store?.accepts(token) != true { return }
        stopping = true; controller.pauseCounting(); stopping = false
        guard let store, flush() else { return }
        if store.updateSession({ try $0.finishSet(at: controller.wallTime) }) { controller.finishDiagnostic(reason: "exerciseFinished"); stop() }
    }

    func useManual(token: TrainingExecutionToken? = nil) {
        if let token, store?.accepts(token) != true { return }
        stopping = true; controller.pauseCounting(); stopping = false
        guard let store, flush() else { return }
        let reason: WorkoutManualReason = controller.cameraState == .denied ? .cameraDenied :
            (controller.cameraState == .unavailable ? .cameraUnavailable :
                (controller.subjectSelection.state == .lost || controller.snapshot.trackingState == .grace ? .trackingLost : .userChoice))
        if store.updateSession({
            try $0.useManualCounting(reason: reason, at: controller.wallTime)
            if $0.stage == .ready || $0.stage == .paused { try $0.startSet(at: controller.wallTime) }
        }) { stop() }
    }

    // Capture one last accepted snapshot without committing. The repository publishes A and B together.
    func quiesce(_ session: inout TrainingSession, at cutoff: Date) throws {
        stopping = true; controller.pauseCounting(); stopping = false
        defer { stop() }
        if session.stage == .active, let binding, let observationId,
           session.currentSetBinding == binding, session.currentObservationId == observationId {
            try session.updateVisual(binding: binding, observationId: observationId, repetitions: controller.repetitions,
                attempts: controller.attempts, droppedAttempts: controller.droppedAttempts, metrics: controller.metrics,
                resetCounts: controller.diagnostics.resetCounts, captureContext: controller.captureContext, at: cutoff)
        }
        if session.stage == .active { try session.pause(at: cutoff) }
        else if session.currentObservationId != nil { try session.cancelVisualPreparation(at: cutoff) }
    }

    func stop(token: TrainingExecutionToken? = nil) {
        if let token, store?.accepts(token) != true { return }
        stopping = true; controller.stopCamera(); stopping = false
        binding = nil; observationId = nil
    }
}
