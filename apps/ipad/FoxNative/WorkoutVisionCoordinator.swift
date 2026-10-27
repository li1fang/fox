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
        controller.onCameraStateChanged = { [weak self] state in
            guard let self, state == .running, self.observationId != nil else { return }
            self.controller.startCounting()
        }
        controller.onCountingBegan = { [weak self] in
            guard let self, let store = self.store, let id = self.observationId,
                  store.session?.currentSetBinding == self.binding else { return false }
            return store.updateSession { try $0.beginVisual(observationId: id, at: self.controller.wallTime) }
        }
        controller.onCountingUpdated = { [weak self] in
            guard let self else { return }
            let now = self.controller.uptime
            if now - self.lastPersistedAt >= 2 || self.lastCount != self.controller.automaticCount { _ = self.flush() }
        }
        controller.onCountingPaused = { [weak self] in
            guard let self, !self.stopping else { return }
            _ = self.pause()
        }
    }

    func prepare(arm: ArmSide) {
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
        controller.diagnosticWorkoutSessionID = session.id
        controller.diagnosticSetAttemptID = session.currentSetAttemptId
        lastPersistedAt = 0; lastCount = 0
        controller.beginTemporaryDiagnostic()
        controller.startCamera()
    }

    // Preview is not an armed start and does not create observation or recording facts.
    func preview() {
        guard let store, store.usesVision, let session = store.session,
              [.ready, .paused].contains(session.stage), session.currentObservationId == nil else { return }
        if controller.cameraState == .stopped { controller.startCamera() }
    }

    func stopUnarmedPreview() {
        guard store?.session?.currentObservationId == nil else { return }
        stop()
    }

    @discardableResult
    func disableVision() -> Bool {
        guard let store, flush() else { return false }
        if store.session?.currentVisualEvidence != nil {
            guard store.updateSession({ try $0.useManualCounting(reason: .userChoice, at: controller.wallTime) }) else { return false }
        }
        stop()
        return true
    }

    @discardableResult
    func flush() -> Bool {
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
    func pause() -> Bool {
        stopping = true; controller.pauseCounting(); stopping = false
        guard let store, flush() else { return false }
        let saved = store.updateSession {
            if $0.stage == .active { try $0.pause(at: controller.wallTime) }
            else if $0.currentObservationId != nil { try $0.cancelVisualPreparation(at: controller.wallTime) }
        }
        if saved { controller.finishDiagnostic(reason: "preparationCancelledOrPaused"); stop() }
        return saved
    }

    func rebindSubject() {
        guard controller.needsRebind else { return }
        let side = controller.arm
        guard pause() else { return }
        prepare(arm: side)
    }

    func finish() {
        stopping = true; controller.pauseCounting(); stopping = false
        guard let store, flush() else { return }
        if store.updateSession({ try $0.finishSet(at: controller.wallTime) }) { controller.finishDiagnostic(reason: "exerciseFinished"); stop() }
    }

    func useManual() {
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

    func stop() {
        stopping = true; controller.stopCamera(); stopping = false
        binding = nil; observationId = nil
    }
}
