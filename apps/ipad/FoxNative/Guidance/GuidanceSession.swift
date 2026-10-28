import AVFoundation
import Combine
import FoxTrainingCore
import UIKit

/// The adapter samples committed session facts and fresh controller observations. It does not
/// take ownership of the coordinator's callbacks, and manual corrections never become spoken reps.
@MainActor
final class GuidanceSession: ObservableObject {
    let output: GuidanceOutputController
    @Published private(set) var mode: GuidanceMode
    private weak var vision: VisionLabController?
    private weak var store: TrainingStore?
    private let defaults: UserDefaults?
    private let standaloneID = UUID().uuidString
    private var timer: Timer?
    private var notifications: [NSObjectProtocol] = []

    init(vision: VisionLabController, store: TrainingStore? = nil, driver: SpeechOutputDriver? = nil,
         defaults: UserDefaults? = .standard) {
        self.vision = vision; self.store = store; self.defaults = defaults
        let modeKey = store == nil ? "FoxGuidance.standaloneMode" : "FoxGuidance.visualMode"
        let storedMode = defaults?.string(forKey: modeKey).flatMap(GuidanceMode.init(rawValue:)) ?? .observed
        mode = store == nil && storedMode == .planned ? .observed : storedMode
        var selectedDriver = driver
        #if DEBUG
        if selectedDriver == nil, ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1",
           ProcessInfo.processInfo.environment["FOX_REAL_SPEECH"] != "1" { selectedDriver = LayoutTestSpeechOutput() }
        #endif
        output = GuidanceOutputController(driver: selectedDriver, now: { [weak vision] in vision?.uptime ?? ProcessInfo.processInfo.systemUptime })
        output.setSpeechEnabled(defaults?.object(forKey: "FoxGuidance.speech") as? Bool ?? true)
        output.overlayEnabled = defaults?.object(forKey: "FoxGuidance.overlay") as? Bool ?? true
        output.onEvent = { [weak vision, weak store] event in
            if let store {
                guard let token = store.executionToken,
                      event.context.sessionID == token.sessionID.uuidString,
                      event.context.attemptID == token.attemptID?.uuidString,
                      event.context.executionGeneration == token.generation.uuidString else { return }
            }
            guard let vision, vision.diagnosticCapture.isActive,
                  let data = try? JSONEncoder().encode(event), let detail = String(data: data, encoding: .utf8) else { return }
            vision.camera.diagnosticEvent(VisionDiagnosticEvent(kind: "guidance", hostUptime: event.time,
                lastCapturePTS: vision.latest?.frame.timestamp, detail: detail))
        }
    }

    func start() {
        guard timer == nil else { return }
        let execution = store?.executionToken
        sample(token: execution)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.store == nil || self.store?.accepts(execution) == true else { return }
                self.sample(token: execution)
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     UIApplication.willResignActiveNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self, self.store == nil || self.store?.accepts(execution) == true else { return }
                    if note.name == AVAudioSession.interruptionNotification {
                        let ended = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.ended.rawValue
                        self.output.suspendSpeech(!ended)
                    } else if note.name == AVAudioSession.routeChangeNotification {
                        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                        self.audioRouteChanged(AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown)
                    } else { self.output.interrupt(reason: note.name.rawValue) }
                }
            })
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications = []
        output.interrupt(reason: "view_inactive")
    }

    func setMode(_ mode: GuidanceMode) {
        self.mode = mode; defaults?.set(mode.rawValue, forKey: store == nil ? "FoxGuidance.standaloneMode" : "FoxGuidance.visualMode")
        output.interrupt(reason: "mode_changed"); sample()
    }
    var usesVision: Bool {
        guard let store else { return true }
        return store.usesVision
    }
    var effectiveMode: GuidanceMode { usesVision || mode == .off ? mode : .planned }
    func setSpeech(_ enabled: Bool) { defaults?.set(enabled, forKey: "FoxGuidance.speech"); output.setSpeechEnabled(enabled) }
    func setOverlay(_ enabled: Bool) { defaults?.set(enabled, forKey: "FoxGuidance.overlay"); output.overlayEnabled = enabled }

    func audioRouteChanged(_ reason: AVAudioSession.RouteChangeReason) {
        output.interrupt(reason: "audio_route_changed")
        // A disconnected headset must not become unexpected speech from the speaker.
        // Later observations may still update the overlay; only an explicit user action unmutes.
        if reason == .oldDeviceUnavailable { setSpeech(false) }
    }

    func sample(token: TrainingExecutionToken? = nil) {
        if let token, store?.accepts(token) != true { return }
        guard let vision else { return }
        let time = vision.uptime
        var snapshot = vision.snapshot
        if vision.subjectSelection.state != .bound { snapshot.quality = .noPerson }
        let motion = MotionObservation(observedAt: vision.observationReceivedUptime, snapshot: snapshot)
        let countdown: Int?
        if case .countdown(let n) = vision.startState { countdown = n } else { countdown = nil }
        if let store {
            guard !store.executionBlocked, let session = store.session else { output.interrupt(reason: "session_ended"); return }
            let visual = store.usesVision
            let stage: GuidanceStage = vision.isPreparing ? (countdown == nil ? .preparing : .countdown) :
                GuidanceStage(rawValue: session.stage.rawValue) ?? .idle
            let context = GuidanceContext(sessionID: session.id.uuidString,
                attemptID: session.currentSetAttemptId?.uuidString ?? "summary",
                observationID: session.currentObservationId?.uuidString ?? session.currentVisualEvidence?.segments.last?.id.uuidString ?? "manual",
                executionGeneration: store.executionGeneration.uuidString)
            output.update(.init(context: context, time: time, stage: stage, exercise: session.exercise.visualObservation?.exercise,
                mode: visual || mode == .off ? mode : .planned, count: session.currentVisualEvidence?.automaticCount ?? 0,
                targetReps: session.target.targetReps, motion: visual ? motion : nil,
                tempo: session.exercise.tempo, elapsed: session.elapsed(at: vision.wallTime), countdown: countdown,
                remainingSets: max(0, session.plan.totalSets - session.records.count),
                restRemainingSeconds: session.stage == .rest ? session.restRemaining(at: vision.wallTime) : nil,
                requiresWeightConfirmation: session.target.weightUnit != "bodyweight",
                plannedCycleLimit: session.exercise.exerciseId == "kegel" ? session.target.targetReps : nil))
        } else {
            let stage: GuidanceStage = vision.isPreparing ? (countdown == nil ? .preparing : .countdown) :
                vision.isCounting ? .active : vision.trialFinished ? .feedback : vision.trialActive ? .paused : .idle
            // Standalone tests have no confirmed training tempo. Planned mode remains unavailable
            // until a plan is explicitly supplied; it must not silently invent a tempo prescription.
            output.update(.init(context: .init(sessionID: standaloneID, attemptID: vision.guidanceAttemptID.uuidString,
                observationID: vision.guidanceObservationID.uuidString), time: time, stage: stage, exercise: vision.exercise,
                mode: mode, count: vision.automaticCount, targetReps: nil, motion: motion, tempo: [], elapsed: 0, countdown: countdown))
        }
    }
}
