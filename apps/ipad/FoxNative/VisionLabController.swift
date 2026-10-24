import AVFoundation
import Combine
import FoxTrainingCore
import SwiftUI
import UIKit
import Vision

@MainActor
final class VisionLabController: ObservableObject {
    static let preparationFlowVersion = "intent-reacquire-v1"
    let camera = PoseCamera()
    let diagnosticCapture: VisionDiagnosticStore
    private var diagnosticChanges: AnyCancellable?
    var diagnosticWorkoutSessionID: UUID?
    var diagnosticSetAttemptID: UUID?
    private let deviceMotion = DevicePoseCapture()
    @Published private(set) var cameraState: PoseCameraState = .stopped
    @Published private(set) var latest: CapturedPose?
    @Published private(set) var reading = PoseReading(quality: .noPerson, angle: nil, confidence: 0, anchor: nil, visiblePoints: 0)
    @Published private(set) var snapshot = CurlSnapshot()
    @Published private(set) var isCounting = false
    @Published private(set) var startState = PoseStartState.idle
    @Published private(set) var arm: ArmSide = .left
    @Published private(set) var exercise = VisionExercise.curl
    @Published private(set) var configuration = PoseCounterConfiguration.standard
    @Published private(set) var subjectSelection = PoseSubjectSelection(state: .waiting)
    private var subjectSelector = PoseSubjectSelector()
    @Published private(set) var runtimePolicy = PoseRuntimePolicy.standard
    @Published private(set) var frontCamera = true
    @Published private(set) var manualAdjustment = 0
    @Published private(set) var lastTrial: VisionTrial?
    @Published private(set) var declaredBodyView = VisionBodyView.unknown
    @Published private(set) var gravity: TimedGravity?
    @Published private(set) var motionStatus = VisionMotionStatus.unavailable
    @Published var errorMessage: String?
    private(set) var trialStartedAt: Date?
    private var trialEndedAt: Date?
    private(set) var guidanceAttemptID = UUID()
    private(set) var guidanceObservationID = UUID()
    var observationReceivedUptime: Double { lastReceivedAt }
    var trialFinished: Bool { trialEndedAt != nil }
    private var tracker = CurlTracker(side: .left)
    private var startGate = PoseStartGate(lossTolerance: PoseRuntimePolicy.standard.countdownLossTolerance)
    private var captureID: UUID?
    private var wantsCamera = false
    private var repository: VisionTrialRepository?
    private var configurationStore: PoseConfigurationStore?
    private let configurationFileURL: URL
    private let sessionSettingsURL: URL
    private var unreadableSessionSettings = false
    private var fixtureTimer: Timer?
    private var fixtureTimeline = PoseFixtureTimeline()
    private var watchdog: Timer?
    private var fixtureTick = 0
    private var fixturePreparationTick = 0
    private var diagnosticSmokeStarted = false
    private var lastReceivedAt = 0.0
    private var lastCaptureTimestamp: Double?
    private var lastReceiptAt = 0.0
    private var latencies: [Double] = []
    private var frameCount = 0
    private var validFrameCount = 0
    private var accumulatedFrameTime = 0.0
    private var frameIntervals = 0
    private var recentFrameTimes: [Double] = []
    private var lastMetricTimestamp: Double?
    private var peakThermal = 0
    private var contextRecorder = VisionContextRecorder()
    private var trialStartedUptime: Double?
    private var trialCameraGeometry: VisionCameraGeometry?
    var screenOrientation = VisionScreenOrientation.unknown
    let reportFileURL: URL
    let fixtureMode: String?
    #if DEBUG
    private var replayClock: VisionReplayClock?
    #endif
    var uptime: TimeInterval {
        #if DEBUG
        if let replayClock { return replayClock.uptime }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }
    var wallTime: Date {
        #if DEBUG
        if let replayClock { return replayClock.date }
        #endif
        return Date()
    }
    var onCameraStateChanged: ((PoseCameraState) -> Void)?
    var onCountingBegan: (() -> Bool)?
    var onCountingUpdated: (() -> Void)?
    var onCountingPaused: (() -> Void)?
    var attempts: [PoseAttemptEvent] { tracker.attempts }
    var droppedAttempts: Int { tracker.droppedAttempts }
    var source: VisionInputSource {
        #if DEBUG
        if replayClock != nil { return .fixture }
        #endif
        return fixtureMode == nil ? .camera : .fixture
    }
    var trialActive: Bool { trialStartedAt != nil }
    var automaticCount: Int { tracker.repetitions.count }
    var confirmedCount: Int { max(0, automaticCount + manualAdjustment) }
    var repetitions: [CurlRepetition] { tracker.repetitions }
    var processingHz: Double {
        guard let first = recentFrameTimes.first, let last = recentFrameTimes.last, last > first else { return 0 }
        return Double(recentFrameTimes.count - 1) / (last - first)
    }
    var isPreparing: Bool { startState.isPreparing }
    var needsRebind: Bool { subjectSelection.state == .lost && isCounting }
    private(set) var preparationReason = "waiting_for_frame"
    var canCount: Bool { cameraState == .running && !isPreparing && !isCounting }
    var selectionLocked: Bool { trialActive || isPreparing || diagnosticCapture.isActive }
    var canSave: Bool { trialActive && repository != nil }
    var framing: VisionFraming? { latest.flatMap { VisionFraming.measure($0.frame) } }
    var contextSampleCount: Int { contextRecorder.samples.count }
    var diagnostics: PoseCounterDiagnostics { tracker.diagnostics }
    var captureContext: VisionCaptureContext {
        VisionCaptureContext(declaredBodyView: declaredBodyView, droppedSamples: contextRecorder.droppedSamples,
            cameraGeometry: trialCameraGeometry, samples: contextRecorder.samples)
    }
    var devicePose: VisionDevicePose? {
        if fixtureMode != nil {
            return fixtureMode == "motion_unavailable" ? nil : VisionDevicePose.measure(gravityX: 0, gravityY: -1, gravityZ: 0,
                frontCamera: frontCamera, source: .fixture)
        }
        guard let gravity else { return nil }
        let age = uptime - gravity.timestamp
        guard age >= 0, age <= 1 else { return nil }
        return VisionDevicePose.measure(gravityX: gravity.x, gravityY: gravity.y, gravityZ: gravity.z,
            frontCamera: frontCamera, source: .coreMotion)
    }
    var currentMotionStatus: VisionMotionStatus {
        status(for: devicePose)
    }
    private func status(for pose: VisionDevicePose?) -> VisionMotionStatus {
        if fixtureMode != nil { return pose == nil ? .unavailable : .fixture }
        return pose != nil ? .available : (motionStatus == .failed ? .failed : .unavailable)
    }
    var qualityLabel: String {
        if cameraState != .running { return cameraState.label }
        if isPreparing || isCounting {
            if subjectSelection.state == .ambiguous { return "主体不明确" }
            if subjectSelection.state == .lost { return "主体丢失，请重新就位" }
            if subjectSelection.state == .occluded { return "主体暂时不可见" }
        }
        if isPreparing {
            if case .countdown = startState { return "准备开始" }
            if subjectSelection.index == nil { return latest?.frame.people.isEmpty == false ? "尚未锁定训练者" : "等待入镜" }
            return preparationReason == "selected_arm_unavailable" ? "所选侧肩肘不清晰" : "等待肩肘稳定"
        }
        if isCounting {
            if snapshot.trackingState == .grace { return "暂时看不清" }
            if snapshot.quality != .valid {
                return snapshot.quality == .discontinuous && exercise == .lateralRaise ? "目标中断，等待重新放低" : snapshot.quality.label
            }
            if snapshot.phase == .waitingForExtension { return exercise.waitingLabel }
            if exercise == .latPulldown {
                switch snapshot.phase {
                case .lowered: return "上方起点"
                case .raising: return "下拉"
                case .top: return "已记次 · 收缩端点"
                case .lowering: return "返回"
                case .waitingForExtension: return exercise.waitingLabel
                }
            }
            if snapshot.phase == .lowered && exercise == .lateralRaise { return "放低" }
            return snapshot.phase.label
        }
        if reading.quality != .valid { return readingQualityLabel }
        return trialActive ? "计数已暂停" : "关键点可见"
    }
    private var readingQualityLabel: String {
        reading.quality == .lowConfidence ? exercise.visibilityLabel : reading.quality.label
    }
    var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常"
        case .fair: return "轻度"
        case .serious: return "明显"
        case .critical: return "严重"
        @unknown default: return "未知"
        }
    }
    var metrics: VisionMetrics {
        let sorted = latencies.sorted()
        func quantile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        return VisionMetrics(processedFrames: frameCount, validFrames: validFrameCount, interruptions: tracker.interruptions,
            processedHz: accumulatedFrameTime > 0 ? Double(frameIntervals) / accumulatedFrameTime : 0,
            latencyP50Ms: quantile(0.5), latencyP95Ms: quantile(0.95),
            peakThermalState: ["nominal", "fair", "serious", "critical"][min(3, max(0, peakThermal))])
    }

    init(diagnosticRoot: URL = VisionDiagnosticArchive.root, storageDirectory: URL? = nil) {
        diagnosticCapture = VisionDiagnosticStore(root: diagnosticRoot)
        let environment = ProcessInfo.processInfo.environment
        let testing = environment["FOX_UI_TESTING"] == "1"
        fixtureMode = testing ? environment["FOX_POSE_FIXTURE"] : nil
        let directory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fox")
        reportFileURL = directory.appendingPathComponent(testing ? "ui-test-vision-trials.json" : "vision-trials.v1.json")
        configurationFileURL = directory.appendingPathComponent(testing ? "ui-test-pose-configuration.json" : "pose-configuration.json")
        sessionSettingsURL = directory.appendingPathComponent(testing ? "ui-test-pose-session-settings.json" : "pose-session-settings.json")
        if testing && ProcessInfo.processInfo.arguments.contains("--ui-testing-reset") { try? FileManager.default.removeItem(at: reportFileURL) }
        if testing && ProcessInfo.processInfo.arguments.contains("--ui-testing-reset") { try? FileManager.default.removeItem(at: configurationFileURL) }
        if testing && ProcessInfo.processInfo.arguments.contains("--ui-testing-reset") { try? FileManager.default.removeItem(at: sessionSettingsURL) }
        do {
            let store = try PoseConfigurationStore(fileURL: configurationFileURL)
            configurationStore = store; configuration = store.configuration
            tracker = CurlTracker(side: arm, exercise: exercise, configuration: configuration, runtimePolicy: runtimePolicy)
        } catch { errorMessage = "参数文件无法读取，原文件已保留，当前使用默认参数。\(error.localizedDescription)" }
        if FileManager.default.fileExists(atPath: sessionSettingsURL.path) {
            do {
                let settings = try PoseSessionSettings.decode(Data(contentsOf: sessionSettingsURL))
                configuration = settings.configuration; runtimePolicy = settings.runtimePolicy
                // Upgrade only active defaults, never archived reports or workout snapshots.
                if runtimePolicy.acquisitionMode == nil { runtimePolicy.acquisitionMode = .singleReadyFallback }
                if runtimePolicy.eccentricPolicy == nil { runtimePolicy.eccentricPolicy = .init() }
                // Upgrade editable live defaults only; archived evidence retains its frozen policy.
                if runtimePolicy.curlRecovery == nil {
                    var candidate = runtimePolicy
                    candidate.curlRecovery = .init()
                    if (try? PoseSessionSettings(configuration: configuration, runtimePolicy: candidate).validate()) != nil {
                        runtimePolicy = candidate
                    }
                }
            } catch {
                unreadableSessionSettings = true
                errorMessage = "运行参数无法读取，原文件已保留。\(error.localizedDescription)"
            }
        }
        if configuration.latPulldown == nil { configuration.latPulldown = .init() }
        if (try? PoseSessionSettings(configuration: configuration, runtimePolicy: runtimePolicy).validate()) == nil {
            let migrated = try! PoseSessionSettings.migrating(configuration: configuration)
            runtimePolicy = migrated.runtimePolicy
            errorMessage = "旧角度设置与新容差冲突，暂时沿用旧角度门槛；参数文件已保留。"
        }
        subjectSelector = PoseSubjectSelector(policy: runtimePolicy)
        startGate = PoseStartGate(lossTolerance: runtimePolicy.countdownLossTolerance)
        tracker = CurlTracker(side: arm, exercise: exercise, configuration: configuration, runtimePolicy: runtimePolicy)
        do {
            let repository = try VisionTrialRepository(fileURL: reportFileURL)
            self.repository = repository
            lastTrial = repository.trials.last
        } catch { errorMessage = error.localizedDescription }
        camera.onFrame = { [weak self] id, frame in
            guard let self, self.wantsCamera, self.captureID == id, self.cameraState == .running else { return }
            self.receive(frame)
        }
        camera.onState = { [weak self] id, state in
            guard let self, self.wantsCamera, self.captureID == id else { return }
            self.cameraState = state
            self.recordDiagnosticEvent("cameraState", detail: state.label)
            if state != .running {
                if state != .starting && state != .requestingPermission {
                    if !self.diagnosticCapture.isActive {
                        self.beginTemporaryDiagnostic()
                        self.recordDiagnosticEvent("cameraState", detail: state.label)
                    }
                    self.finishDiagnostic(reason: "cameraInterrupted")
                }
                self.pauseCounting()
                self.invalidateMotion(clearPreview: true)
            }
            self.onCameraStateChanged?(state)
        }
        camera.onDiscontinuity = { [weak self] id in
            guard let self, self.captureID == id else { return }
            self.recordDiagnosticEvent("cameraDiscontinuity")
            self.invalidateMotion(clearPreview: true)
        }
        camera.onDiagnosticResult = { [capture = diagnosticCapture] id, result in capture.receive(id: id, result: result) }
        // Selection locking depends on async recording finalization, even when no camera frame arrives.
        diagnosticChanges = diagnosticCapture.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        diagnosticCapture.onLimit = { [weak self] in self?.finishDiagnostic(reason: "durationLimit") }
        deviceMotion.onReading = { [weak self] id, reading in
            guard let self, self.wantsCamera, self.captureID == id else { return }
            self.gravity = reading
        }
        deviceMotion.onStatus = { [weak self] id, status in
            guard let self, self.wantsCamera, self.captureID == id else { return }
            if self.motionStatus != status { self.motionStatus = status }
            if status != .available { self.gravity = nil }
        }
    }

    func startCamera() {
        guard !wantsCamera else { return }
        wantsCamera = true
        lastReceivedAt = uptime
        let id = UUID()
        captureID = id
        lastCaptureTimestamp = nil
        #if DEBUG
        if replayClock != nil { camera.onState?(id, .running); return }
        #endif
        if let fixtureMode {
            if fixtureMode == "denied" {
                cameraState = .denied; beginTemporaryDiagnostic(); finishDiagnostic(reason: "cameraUnavailable")
                onCameraStateChanged?(cameraState); return
            }
            cameraState = .running
            fixtureTimeline = PoseFixtureTimeline()
            fixtureTimer = Timer.scheduledTimer(withTimeInterval: PoseFixtureTimeline.frameInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.receiveFixtureTick(capture: id) }
            }
            onCameraStateChanged?(cameraState)
            if environmentDiagnosticSmoke && !diagnosticSmokeStarted {
                diagnosticSmokeStarted = true
                startCounting()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.pauseCounting(); self?.finishDiagnostic(reason: "fixtureSmoke"); self?.stopCamera()
                }
            }
            return
        }
        #if targetEnvironment(simulator)
        cameraState = .unavailable
        #else
        cameraState = .starting
        deviceMotion.start(id: id)
        camera.start(position: frontCamera ? .front : .back, id: id)
        #endif
        onCameraStateChanged?(cameraState)
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWatchdog() }
        }
    }

    private func checkWatchdog() {
        guard wantsCamera, cameraState == .running, uptime - lastReceivedAt > 1 else { return }
        recordDiagnosticEvent("watchdogTimeout")
        invalidateMotion(clearPreview: true)
    }

    #if DEBUG
    // App tests drive the production callbacks and clock without opening a camera or recording media.
    func enableReplay(clock: VisionReplayClock) {
        precondition(!wantsCamera && !trialActive)
        replayClock = clock
    }
    var replayCaptureID: UUID? { captureID }
    func replayFrame(_ value: CapturedPose, capture: UUID? = nil) {
        precondition(replayClock != nil)
        if let id = capture ?? captureID { camera.onFrame?(id, value) }
    }
    func replayWatchdog() { precondition(replayClock != nil); checkWatchdog() }
    func replayFixtureTick() {
        precondition(replayClock != nil)
        guard let captureID else { return }
        receiveFixtureTick(capture: captureID)
    }
    func replayDiscontinuity() {
        precondition(replayClock != nil)
        if let id = captureID { camera.onDiscontinuity?(id) }
    }
    #endif

    func stopCamera() {
        finishDiagnostic(reason: "cameraStopped")
        wantsCamera = false; captureID = nil
        fixtureTimer?.invalidate(); fixtureTimer = nil
        watchdog?.invalidate(); watchdog = nil
        camera.stop()
        deviceMotion.stop(); gravity = nil; motionStatus = .unavailable
        pauseCounting()
        cameraState = .stopped
        latest = nil
        recentFrameTimes = []
        writeLiveReceipt()
    }

    func retryCamera() { stopCamera(); startCamera() }
    func changeCamera(_ front: Bool, restartPreview: Bool = true) {
        guard !selectionLocked, frontCamera != front else { return }
        stopCamera(); frontCamera = front
        if restartPreview { startCamera() }
    }
    func changeArm(_ side: ArmSide) {
        guard !selectionLocked else { return }
        arm = side; tracker = CurlTracker(side: side, exercise: exercise, configuration: configuration, runtimePolicy: runtimePolicy); manualAdjustment = 0
        snapshot = tracker.snapshot
        if let latest { reading = PoseGeometry.inspect(latest.frame, side: side, exercise: exercise, configuration: configuration, runtimePolicy: runtimePolicy) }
    }

    func changeExercise(_ value: VisionExercise) {
        guard !selectionLocked, value != exercise else { return }
        exercise = value; tracker = CurlTracker(side: arm, exercise: value, configuration: configuration, runtimePolicy: runtimePolicy)
        snapshot = tracker.snapshot; manualAdjustment = 0
        declaredBodyView = .unknown
        if let latest { reading = PoseGeometry.inspect(latest.frame, side: arm, exercise: value, configuration: configuration, runtimePolicy: runtimePolicy) }
    }

    func applyConfiguration(_ value: PoseCounterConfiguration, runtimePolicy policy: PoseRuntimePolicy? = nil) throws {
        guard !selectionLocked else { throw PoseConfigurationError.invalid }
        let settings = PoseSessionSettings(configuration: value, runtimePolicy: policy ?? runtimePolicy)
        try settings.validate()
        try FileManager.default.createDirectory(at: sessionSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if unreadableSessionSettings {
            try FileManager.default.copyItem(at: sessionSettingsURL, to: sessionSettingsURL.appendingPathExtension("invalid-\(UUID().uuidString)"))
        }
        try LocalTrainingRepository.encoder().encode(settings).write(to: sessionSettingsURL, options: .atomic)
        unreadableSessionSettings = false
        configuration = value; runtimePolicy = settings.runtimePolicy
        subjectSelector = PoseSubjectSelector(policy: runtimePolicy); subjectSelection = subjectSelector.selection
        startGate = PoseStartGate(lossTolerance: runtimePolicy.countdownLossTolerance)
        tracker = CurlTracker(side: arm, exercise: exercise, configuration: value, runtimePolicy: runtimePolicy)
        snapshot = tracker.snapshot
        if let latest { reading = PoseGeometry.inspect(latest.frame, side: arm, exercise: exercise, configuration: value, runtimePolicy: runtimePolicy) }
    }

    func changeBodyView(_ view: VisionBodyView) {
        guard !selectionLocked else { return }
        declaredBodyView = view
    }

    func startCounting() {
        guard canCount else { return }
        fixtureTimeline.controlBoundary(receivedAt: uptime)
        beginTemporaryDiagnostic()
        recordDiagnosticEvent("prepareRequested")
        if !trialActive {
            guidanceAttemptID = UUID()
            tracker = CurlTracker(side: arm, exercise: exercise, configuration: configuration, runtimePolicy: runtimePolicy); manualAdjustment = 0; fixtureTick = 0
            snapshot = tracker.snapshot
        }
        fixturePreparationTick = 0
        guidanceObservationID = UUID()
        preparationReason = "waiting_for_frame"
        subjectSelector.reset(); subjectSelection = subjectSelector.selection
        startGate.arm(); startState = startGate.state
    }

    func rebindSubject() {
        guard needsRebind else { return }
        pauseCounting()
        startCounting()
    }

    private func beginCounting() {
        guard onCountingBegan?() ?? true else { pauseCounting(); return }
        recordDiagnosticEvent("countingBegan")
        if !trialActive {
            trialStartedAt = wallTime; trialEndedAt = nil
            tracker = CurlTracker(side: arm, exercise: exercise, configuration: configuration, runtimePolicy: runtimePolicy); manualAdjustment = 0; fixtureTick = 0
            latencies = []; frameCount = 0; validFrameCount = 0; accumulatedFrameTime = 0; frameIntervals = 0
            peakThermal = ProcessInfo.processInfo.thermalState.rawValue
            contextRecorder = VisionContextRecorder(); trialStartedUptime = lastReceivedAt
            trialCameraGeometry = latest?.cameraGeometry
        } else { tracker.interrupt() }
        trialEndedAt = nil
        lastMetricTimestamp = nil
        isCounting = true
        snapshot = tracker.snapshot
    }

    func pauseCounting() {
        fixtureTimeline.controlBoundary(receivedAt: uptime)
        recordDiagnosticEvent(isPreparing ? "preparationCancelled" : "countingPaused")
        let wasCounting = isCounting
        let wasPreparing = isPreparing
        startGate.cancel(); startState = startGate.state
        if isCounting { tracker.interrupt() }
        isCounting = false; lastMetricTimestamp = nil
        snapshot = tracker.snapshot
        if wasCounting || wasPreparing { onCountingPaused?() }
    }
    func correct(by delta: Int) {
        guard trialActive, (0...10000).contains(automaticCount + manualAdjustment + delta) else { return }
        manualAdjustment += delta
        recordDiagnosticEvent("manualCorrection", detail: String(delta))
    }
    func finishCounting() { pauseCounting(); trialEndedAt = wallTime; finishDiagnostic(reason: "exerciseFinished") }

    private var environmentDiagnosticSmoke: Bool {
        ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1" &&
        ProcessInfo.processInfo.environment["FOX_DIAGNOSTIC_SMOKE"] == "1" && fixtureMode != nil
    }
    func beginTemporaryDiagnostic() {
        #if DEBUG
        if replayClock != nil { return }
        #endif
        guard !diagnosticCapture.isActive, !diagnosticCapture.finishing else { return }
        let context = VisionDiagnosticContext(source: source,
            device: UIDevice.current.model + " / " + UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            camera: frontCamera ? "front" : "back", exercise: exercise, arm: arm, bodyView: declaredBodyView,
            screenOrientation: screenOrientation, configuration: configuration, runtimePolicy: runtimePolicy,
            visionRevision: latest?.revision ?? VNDetectHumanBodyPoseRequest.currentRevision,
            workoutSessionID: diagnosticWorkoutSessionID, setAttemptID: diagnosticSetAttemptID,
            hardwareModel: VisionDiagnosticArchive.hardwareModel())
        guard diagnosticCapture.begin(context) else { return }
        camera.beginDiagnostic(context: context, root: diagnosticCapture.draftRoot)
        recordDiagnosticEvent("recordingRequested")
        if cameraState == .denied || cameraState == .restricted || cameraState == .unavailable {
            finishDiagnostic(reason: "cameraUnavailable")
        }
    }
    func finishDiagnostic(reason: String) {
        guard diagnosticCapture.isActive, !diagnosticCapture.finishing else { return }
        diagnosticCapture.markFinishing()
        camera.endDiagnostic(reason: reason)
    }
    private func recordDiagnosticEvent(_ kind: String, detail: String? = nil) {
        guard diagnosticCapture.isActive, !diagnosticCapture.finishing else { return }
        camera.diagnosticEvent(VisionDiagnosticEvent(kind: kind, lastCapturePTS: latest?.frame.timestamp, detail: detail))
    }

    func configureWorkout(settings: WorkoutObservationSettings, configuration: PoseCounterConfiguration, runtimePolicy: PoseRuntimePolicy) throws {
        try settings.validate()
        try PoseSessionSettings(configuration: configuration, runtimePolicy: runtimePolicy).validate()
        stopCamera()
        trialStartedAt = nil; trialEndedAt = nil; trialStartedUptime = nil
        arm = settings.arm; exercise = settings.exercise; declaredBodyView = settings.bodyView; frontCamera = true
        self.configuration = configuration; self.runtimePolicy = runtimePolicy
        subjectSelector = PoseSubjectSelector(policy: runtimePolicy); subjectSelection = subjectSelector.selection
        startGate = PoseStartGate(lossTolerance: runtimePolicy.countdownLossTolerance); startState = startGate.state
        tracker = CurlTracker(side: arm, exercise: exercise, configuration: configuration, runtimePolicy: runtimePolicy)
        snapshot = tracker.snapshot; manualAdjustment = 0; frameCount = 0; validFrameCount = 0
    }

    func saveReport(referenceCount: Int?, notes: String, bodyView: VisionBodyView? = nil, review: TrialReview? = nil) -> Bool {
        guard let start = trialStartedAt, let repository else { return false }
        var report = VisionTrial(startedAt: start, endedAt: trialEndedAt ?? wallTime,
            device: UIDevice.current.model + " / " + UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            visionRevision: latest?.revision ?? VNDetectHumanBodyPoseRequest.currentRevision,
            source: source, camera: frontCamera ? "front" : "back", arm: arm, repetitions: tracker.repetitions,
            manualAdjustment: manualAdjustment, referenceCount: referenceCount, metrics: metrics, notes: notes,
            captureContext: VisionCaptureContext(declaredBodyView: bodyView ?? declaredBodyView,
                droppedSamples: contextRecorder.droppedSamples, cameraGeometry: trialCameraGeometry, samples: contextRecorder.samples),
            exercise: exercise, counterDiagnostics: tracker.diagnostics)
        report.trialReview = review
        do {
            try repository.append(report)
            lastTrial = report; trialStartedAt = nil; trialEndedAt = nil; trialStartedUptime = nil
            declaredBodyView = bodyView ?? declaredBodyView
            return true
        } catch { errorMessage = "验证未保存：\(error.localizedDescription)"; return false }
    }

    func exportLatest() -> URL? {
        guard let lastTrial else { return nil }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fox-vision-\(lastTrial.id).json")
            try LocalTrainingRepository.encoder().encode(lastTrial).write(to: url, options: .atomic)
            return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    private func receive(_ value: CapturedPose) {
        guard value.frame.timestamp.isFinite,
              lastCaptureTimestamp.map({ value.frame.timestamp > $0 }) ?? true else {
            recordDiagnosticEvent("frameRejected", detail: "non_monotonic_capture_pts")
            return
        }
        lastCaptureTimestamp = value.frame.timestamp
        lastReceivedAt = uptime
        recentFrameTimes.append(lastReceivedAt)
        if recentFrameTimes.count > 30 { recentFrameTimes.removeFirst() }
        latest = value
        var selectedFrame = value.frame
        if isPreparing || isCounting {
            let previous = subjectSelection.state
            subjectSelection = subjectSelector.process(value.frame, side: arm)
            // A preparation request survives walking away from the screen. Active sets remain locked on loss.
            if isPreparing && subjectSelection.state == .lost {
                subjectSelector.reset()
                startGate.invalidate()
                subjectSelection = subjectSelector.process(value.frame, side: arm)
                recordDiagnosticEvent("preparationReacquiring")
            }
            if isPreparing && subjectSelection.state == .ambiguous { startGate.invalidate() }
            selectedFrame = subjectSelection.selectedFrame(from: value.frame)
            if isCounting, subjectSelection.state == .lost, previous != .lost { tracker.interrupt() }
        }
        reading = PoseGeometry.inspect(selectedFrame, side: arm, exercise: exercise, configuration: configuration,
                                       tracking: isCounting && snapshot.trackingState != .acquiring && snapshot.trackingState != .lost,
                                       runtimePolicy: runtimePolicy)
        if isPreparing {
            let ready = PoseSubjectSelector.isReady(selectedFrame, side: arm, confidence: runtimePolicy.subjectConfidence)
            let reason: String
            switch subjectSelection.state {
            case .ambiguous: reason = "ambiguous_subject"
            case .lost: reason = "subject_lost_rebind_required"
            case .occluded: reason = "subject_occluded"
            case .waiting: reason = value.frame.people.isEmpty ? "no_subject" : "no_eligible_subject"
            case .bound: reason = ready ? "stabilizing_or_countdown" : "selected_arm_unavailable"
            }
            if reason != preparationReason {
                preparationReason = reason
                recordDiagnosticEvent("preparationReason", detail: reason)
            }
            startState = startGate.process(timestamp: value.frame.timestamp,
                poseReady: ready)
            if startState == .ready {
                startGate.cancel(); startState = startGate.state
                beginCounting()
            }
        }
        if isCounting {
            snapshot = tracker.process(selectedFrame, originalPeopleCount: value.frame.people.count, selection: subjectSelection)
            frameCount += 1
            if reading.quality == .valid { validFrameCount += 1 }
            if let previous = lastMetricTimestamp {
                accumulatedFrameTime += max(0, value.frame.timestamp - previous)
                frameIntervals += 1
            }
            lastMetricTimestamp = value.frame.timestamp
            if latencies.count < 10000 { latencies.append(value.latencyMs) }
            peakThermal = max(peakThermal, ProcessInfo.processInfo.thermalState.rawValue)
            if let started = trialStartedUptime {
                let pose = devicePose
                contextRecorder.record(elapsedSeconds: lastReceivedAt - started, screenOrientation: screenOrientation,
                    motionStatus: status(for: pose), devicePose: pose, frame: selectedFrame, side: arm,
                    automaticCount: automaticCount, interruptions: tracker.interruptions, exercise: exercise,
                    configuration: configuration, runtimePolicy: runtimePolicy)
            }
            onCountingUpdated?()
        }
        if source == .camera, lastReceivedAt - lastReceiptAt > 2 {
            lastReceiptAt = lastReceivedAt
            writeLiveReceipt()
        }
        if diagnosticCapture.isActive && !diagnosticCapture.finishing {
            let state: String
            switch startState {
            case .idle: state = "idle"
            case .waiting: state = "waiting"
            case .countdown(let seconds): state = "countdown-\(seconds)"
            case .ready: state = "ready"
            }
            let people = value.frame.people.map { body in body.points.keys.sorted { $0.rawValue < $1.rawValue }.map { joint in
                let point = body.points[joint]!
                return PoseTraceJoint(joint: joint, x: point.x, y: point.y, confidence: point.confidence)
            } }
            camera.diagnosticPose(VisionDiagnosticPose(capturePTS: value.frame.timestamp, receivedUptime: lastReceivedAt,
                width: value.frame.width, height: value.frame.height, people: people, subjectState: subjectSelection.state.rawValue,
                selectedSubjectIndex: subjectSelection.index, startState: state, isCounting: isCounting,
                automaticCount: automaticCount, countingPhase: snapshot.phase.rawValue,
                failureReason: snapshot.failureReason?.rawValue ?? reading.failureReason?.rawValue,
                readingQuality: reading.quality.rawValue, angle: reading.angle, latencyMs: value.latencyMs,
                screenOrientation: screenOrientation, devicePose: devicePose, cameraGeometry: value.cameraGeometry,
                motionStatus: currentMotionStatus, framing: VisionFraming.measure(selectedFrame)))
        }
    }

    private func invalidateMotion(clearPreview: Bool) {
        recordDiagnosticEvent("trackingInvalidated", detail: clearPreview ? "previewCleared" : nil)
        if isCounting { pauseCounting() }
        startGate.invalidate(); startState = startGate.state
        subjectSelector.reset(); subjectSelection = subjectSelector.selection
        tracker.interrupt(); snapshot = tracker.snapshot
        lastMetricTimestamp = nil
        if clearPreview {
            latest = nil
            reading = PoseReading(quality: .invalidFrame, angle: nil, confidence: 0, anchor: nil, visiblePoints: 0)
        }
    }

    private func receiveFixtureTick(capture: UUID) {
        let generation = fixtureTimeline.generation
        for timestamp in fixtureTimeline.samplesDue(receivedAt: uptime) {
            guard wantsCamera, captureID == capture, fixtureTimeline.generation == generation else { break }
            receiveFixture(timestamp: timestamp)
        }
    }

    private func receiveFixture(timestamp: TimeInterval) {
        if isPreparing { fixturePreparationTick += 1 }
        // Normal UI fixtures stay clear of the minimum-duration boundary; core tests cover too-fast motion.
        let sequence = exercise == .latPulldown ?
            [150.0,150,150,150,150,140,130,120,110,108,105,100,98,96,85,75,70,70,70,70,
             70,70,80,90,105,115,125,135,145,150,150,150,150] :
            [160.0, 160, 160, 160, 160, 140, 120, 100, 80, 55, 55, 55, 55,
                        75, 100, 100, 120, 120, 140, 140, 160, 160, 160, 160, 160, 160]
        let angle = isCounting && fixtureTick < sequence.count * 2 ? sequence[fixtureTick % sequence.count] : 160
        if isCounting { fixtureTick += 1 }
        let radians = angle * .pi / 180
        var points: [PoseJoint: PosePoint] = [
            .nose: PosePoint(x: 0.5, y: 0.92), .neck: PosePoint(x: 0.5, y: 0.82), .root: PosePoint(x: 0.5, y: 0.43),
            .leftShoulder: PosePoint(x: 0.38, y: 0.8), .rightShoulder: PosePoint(x: 0.62, y: 0.8),
            .leftElbow: PosePoint(x: 0.38, y: 0.55), .rightElbow: PosePoint(x: 0.62, y: 0.55),
            .leftWrist: PosePoint(x: 0.38, y: 0.33), .rightWrist: PosePoint(x: 0.62, y: 0.33),
            .leftHip: PosePoint(x: 0.42, y: 0.43), .rightHip: PosePoint(x: 0.58, y: 0.43),
            .leftKnee: PosePoint(x: 0.42, y: 0.25), .rightKnee: PosePoint(x: 0.58, y: 0.25),
            .leftAnkle: PosePoint(x: 0.42, y: 0.06), .rightAnkle: PosePoint(x: 0.58, y: 0.06)
        ]
        let elbowX = arm == .left ? 0.38 : 0.62
        let bendDirection = arm == .left ? 1.0 : -1.0
        points[arm.joints[2]] = PosePoint(x: elbowX + bendDirection * sin(radians) * 0.22 * 1280 / 720,
                                       y: 0.55 + cos(radians) * 0.22)
        if exercise == .lateralRaise {
            let raises = [10.0, 10, 10, 10, 10, 25, 40, 55, 65, 70, 85, 85, 85, 85, 75, 65, 55, 45, 35, 25, 15, 10, 10, 10, 10, 10, 10]
            let tick = max(0, fixtureTick - 1)
            let angle = isCounting && tick < raises.count * 2 ? raises[tick % raises.count] : 10
            let r = angle * .pi / 180, direction = arm == .left ? -1.0 : 1.0
            points[arm == .left ? .leftHip : .rightHip] = PosePoint(x: elbowX, y: 0.43)
            points[arm.joints[1]] = PosePoint(x: elbowX + direction * sin(r) * 0.14 * 1280 / 720, y: 0.8 - cos(r) * 0.14)
            points[arm.joints[2]] = PosePoint(x: elbowX + direction * sin(r) * 0.21 * 1280 / 720, y: 0.8 - cos(r) * 0.21)
        }
        if exercise == .latPulldown {
            let extent = max(0, min(1, (angle - 70) / 80)), direction = -.pi / 2 + extent * .pi * 0.65
            let shoulder = PosePoint(x: 0.4, y: 0.5)
            let elbow = PosePoint(x: shoulder.x + cos(direction) * 0.16 * 1280 / 720, y: shoulder.y + sin(direction) * 0.16)
            let wristDirection = direction + .pi - radians
            points = [arm.joints[0]: shoulder, arm.joints[1]: elbow,
                arm.joints[2]: PosePoint(x: elbow.x + cos(wristDirection) * 0.16 * 1280 / 720, y: elbow.y + sin(wristDirection) * 0.16)]
        }
        if fixtureMode == "missing_hip" { points.removeValue(forKey: .leftHip); points.removeValue(forKey: .rightHip) }
        if fixtureMode == "same_hip_missing" { points.removeValue(forKey: arm == .left ? .leftHip : .rightHip) }
        if fixtureMode == "walk_in" {
            let otherArm: ArmSide = arm == .left ? .right : .left
            otherArm.joints.forEach { points.removeValue(forKey: $0) }
        }
        if fixtureMode == "low_confidence" { points[arm.joints[2]]?.confidence = 0.2 }
        if fixtureMode == "flicker", isCounting, [7, 15].contains(fixtureTick % 27) {
            points[arm.joints[1]]?.confidence = 0.1
        }
        var people = fixtureMode == "no_person" ? [] : [BodyPose(points: points)]
        if fixtureMode == "walk_in", !isCounting, (!isPreparing || fixturePreparationTick <= 20) { people = [] }
        if fixtureMode == "countdown_loss", isPreparing, (15...22).contains(fixturePreparationTick) { people = [] }
        if fixtureMode == "preparation_retreat", isPreparing, (12...39).contains(fixturePreparationTick) { people = [] }
        if fixtureMode == "subject_loss", isCounting, (28...50).contains(fixtureTick) { people = [] }
        if fixtureMode == "multiple" { people.append(BodyPose(points: points)) }
        if fixtureMode == "background" {
            let background = points.mapValues { PosePoint(x: 0.85 + ($0.x - 0.5) * 0.2, y: 0.45 + ($0.y - 0.8) * 0.2, confidence: $0.confidence) }
            if fixtureTick % 2 == 0 { people.insert(BodyPose(points: background), at: 0) }
            else { people.append(BodyPose(points: background)) }
        }
        let frame = PoseFrame(timestamp: timestamp, width: 720, height: 1280, people: people)
        if diagnosticCapture.isActive && !diagnosticCapture.finishing { camera.diagnosticFixtureFrame(frame) }
        receive(CapturedPose(frame: frame,
            latencyMs: 1, revision: 1, cameraGeometry: VisionCameraGeometry(deviceType: "fixture", zoomFactor: 1, reportedFormatFieldOfViewDegrees: 60)))
    }

    private func writeLiveReceipt() {
        guard source == .camera, ProcessInfo.processInfo.environment["FOX_UI_TESTING"] != "1" else { return }
        struct Receipt: Encodable {
            var schema = "fox.vision_live_status.v1"
            let recordedAt: Date
            let frameReceivedAt: Date?
            let source = "camera"
            let exercise: VisionExercise
            let algorithm: String
            let configurationName: String
            let trackingState: PoseTrackingState
            let phase: CurlPhase
            let failureReason: PoseFailureReason?
            let automaticCount: Int
            let cameraRunning: Bool
            let people: Int
            let visiblePoints: Int
            let latencyMs: Double?
            let revision: Int?
            let devicePose: VisionDevicePose?
            let motionStatus: VisionMotionStatus
            let framing: VisionFraming?
            let screenOrientation: VisionScreenOrientation
        }
        let age = ProcessInfo.processInfo.systemUptime - lastReceivedAt
        let pose = devicePose
        let receipt = Receipt(recordedAt: Date(), frameReceivedAt: latest == nil ? nil : Date().addingTimeInterval(-max(0, age)),
            exercise: exercise, algorithm: exercise.algorithm(runtimePolicy: runtimePolicy), configurationName: configuration.name,
            trackingState: snapshot.trackingState, phase: snapshot.phase, failureReason: snapshot.failureReason,
            automaticCount: automaticCount, cameraRunning: cameraState == .running, people: latest?.frame.people.count ?? 0,
            visiblePoints: reading.visiblePoints, latencyMs: latest?.latencyMs, revision: latest?.revision,
            devicePose: pose, motionStatus: status(for: pose), framing: framing, screenOrientation: screenOrientation)
        let url = reportFileURL.deletingLastPathComponent().appendingPathComponent("vision-live-status.v1.json")
        // This scalar diagnostic receipt contains no image, audio, or joint coordinates.
        let data = try? LocalTrainingRepository.encoder().encode(receipt)
        if let data {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
