import Foundation

public enum PoseCountingBasis: String, Codable { case contractedEndpoint }

/// Published by the following accepted peak, never by terminal relaxation. Index is zero-based within the segment.
public struct PoseReturnObservation: Codable, Equatable {
    public var repetitionIndex: Int
    public var measurement: PoseEccentricMeasurement
}

public struct LatPulldownPolicy: Codable, Equatable {
    public var schema = "fox.lat_pulldown_policy.v1"
    public var angles = PoseExerciseProfile(loweredAngleDegrees: 130, departureAngleDegrees: 115,
        peakAngleDegrees: 95, returnAngleDegrees: 110, requiresWrist: true)
    public var acquisitionConfidence = 0.45
    public var trackingConfidence = 0.30
    // Pixel-aspect-corrected vertical wrist displacement / upper-arm length. Not a metric distance.
    public var minimumOverheadWrist = 0.6
    public var maximumContractedWrist = 0.35
    public init() {}
    public func validate() throws {
        let a = angles.cycleAngles(for: .latPulldown)
        guard schema == "fox.lat_pulldown_policy.v1", angles.requiresWrist,
              [a.bottom,a.departure,a.peak,a.returning].allSatisfy({ $0.isFinite && (0...180).contains($0) }),
              a.peak < a.returning, a.returning < a.departure, a.departure < a.bottom,
              (0.3...0.6).contains(trackingConfidence), (trackingConfidence...0.8).contains(acquisitionConfidence),
              (0.4...1.2).contains(minimumOverheadWrist), (-0.2...0.5).contains(maximumContractedWrist),
              maximumContractedWrist < minimumOverheadWrist else { throw PoseConfigurationError.invalid }
    }
}

/// Compatibility facade: legacy arm algorithms keep their original state transitions.
public struct CurlTracker {
    public let side: ArmSide
    public let exercise: VisionExercise
    public let configuration: PoseCounterConfiguration
    public let runtimePolicy: PoseRuntimePolicy?
    private var legacy: LegacyArmTracker?
    private var pulldown: LatPulldownTracker?
    public var diagnostics: PoseCounterDiagnostics { pulldown?.diagnostics ?? legacy!.diagnostics }
    public var repetitions: [CurlRepetition] { pulldown?.repetitions ?? legacy!.repetitions }
    public var attempts: [PoseAttemptEvent] { pulldown?.attempts ?? legacy!.attempts }
    public var droppedAttempts: Int { pulldown?.droppedAttempts ?? legacy!.droppedAttempts }
    public var interruptions: Int { pulldown?.interruptions ?? legacy!.interruptions }
    public var snapshot: CurlSnapshot {
        var value = pulldown?.snapshot ?? legacy!.snapshot
        value.returnPhaseObservation = exercise == .latPulldown ? pulldown?.returnPhaseObservation : legacy?.returnPhaseObservation
        return value
    }
    public init(side: ArmSide, exercise: VisionExercise = .curl, configuration: PoseCounterConfiguration = .standard,
                runtimePolicy: PoseRuntimePolicy? = nil) {
        precondition((try? configuration.validate()) != nil)
        precondition(runtimePolicy == nil || (try? PoseSessionSettings(configuration: configuration, runtimePolicy: runtimePolicy!).validate()) != nil)
        self.side = side; self.exercise = exercise; self.configuration = configuration; self.runtimePolicy = runtimePolicy
        if exercise == .latPulldown { pulldown = LatPulldownTracker(side: side, configuration: configuration, runtimePolicy: runtimePolicy) }
        else { legacy = LegacyArmTracker(side: side, exercise: exercise, configuration: configuration, runtimePolicy: runtimePolicy) }
    }
    @discardableResult public mutating func process(_ frame: PoseFrame, originalPeopleCount: Int? = nil,
                                                   selection: PoseSubjectSelection? = nil) -> CurlSnapshot {
        if exercise == .latPulldown { _ = pulldown!.process(frame, originalPeopleCount: originalPeopleCount, selection: selection) }
        else { _ = legacy!.process(frame, originalPeopleCount: originalPeopleCount, selection: selection) }
        return snapshot
    }
    public mutating func interrupt() {
        if exercise == .latPulldown { pulldown!.interrupt() } else { legacy!.interrupt() }
    }
}

/// motion-strategy-lat-pulldown: shoulder/elbow readiness is weaker than shoulder/elbow/wrist counting.
/// Commit a sustained contracted endpoint once; later loss never erases that fact. Only the next
/// accepted peak can publish the preceding return, so terminal relaxation never becomes eccentric evidence.
private struct LatPulldownTracker {
    let side: ArmSide
    let configuration: PoseCounterConfiguration
    let runtimePolicy: PoseRuntimePolicy?
    var diagnostics: PoseCounterDiagnostics
    var repetitions: [CurlRepetition] = []
    var attempts: [PoseAttemptEvent] = []
    var droppedAttempts = 0
    var interruptions = 0
    var snapshot = CurlSnapshot()
    private var origin: Double?
    private var lastTime: Double?
    private var acceptedAt: Double?
    private var anchor: PosePoint?
    private var rawAngle: Double?
    private var angle: Double?
    private var dwellAt: Double?
    private var pullAt: Double?
    private var phaseAt: Double?
    private var gapSeconds = 0.0
    private var minimumConfidence = 1.0
    private var estimator: PulldownReturnEstimator?
    private var pendingReturn: PoseReturnObservation?
    var returnPhaseObservation: PoseReturnPhaseObservation? {
        [.top, .lowering].contains(snapshot.phase) ? estimator?.currentPhaseObservation : nil
    }

    init(side: ArmSide, configuration: PoseCounterConfiguration, runtimePolicy: PoseRuntimePolicy?) {
        self.side = side; self.configuration = configuration; self.runtimePolicy = runtimePolicy
        diagnostics = PoseCounterDiagnostics(configuration: configuration, runtimePolicy: runtimePolicy)
    }

    mutating func process(_ frame: PoseFrame, originalPeopleCount: Int?, selection: PoseSubjectSelection?) -> CurlSnapshot {
        guard frame.timestamp.isFinite, lastTime.map({ frame.timestamp > $0 }) ?? true else { return snapshot }
        let now = frame.timestamp, p = configuration.tracking, action = configuration.pulldown
        let delta = lastTime.map { now - $0 } ?? 0
        lastTime = now; if origin == nil { origin = now }
        snapshot.failureReason = nil
        if delta > p.maximumFrameGapSeconds { reset(.frameGap) }
        if let acceptedAt, now - acceptedAt > p.graceSeconds + 0.000001 { reset(.dropoutTimeout) }
        let reading = PoseGeometry.inspect(frame, side: side, exercise: .latPulldown, configuration: configuration,
            tracking: acceptedAt != nil, runtimePolicy: runtimePolicy)
        defer { record(frame, reading: reading, originalPeopleCount: originalPeopleCount, selection: selection) }
        snapshot.quality = reading.quality; snapshot.angle = reading.angle; snapshot.confidence = reading.confidence
        guard reading.quality == .valid, let raw = reading.angle, let shoulder = reading.anchor else {
            reject(reading.failureReason ?? .lowConfidence, at: now, immediate: reading.quality == .multiplePeople || reading.quality == .invalidFrame)
            return snapshot
        }
        if let anchor, hypot(anchor.x - shoulder.x, anchor.y - shoulder.y) > p.maximumAnchorJump {
            reject(.anchorJump, at: now); snapshot.quality = .discontinuous; return snapshot
        }
        if let rawAngle, abs(rawAngle - raw) > p.maximumAngleJumpDegrees {
            reject(.angleJump, at: now); snapshot.quality = .discontinuous; return snapshot
        }
        let acceptedDelta = acceptedAt.map { now - $0 } ?? 0
        if snapshot.trackingState == .grace {
            diagnostics.recoveries += 1
            if pullAt != nil { gapSeconds += acceptedDelta }
        }
        acceptedAt = now; anchor = shoulder; rawAngle = raw
        let alpha = acceptedDelta > 0 ? 1 - exp(-acceptedDelta / p.smoothingSeconds) : 1
        let smooth = angle.map { $0 + alpha * (raw - $0) } ?? raw
        angle = smooth; snapshot.angle = smooth; snapshot.trackingState = .tracking
        let points = frame.people[0].points, elbow = points[side.joints[1]]!, wrist = points[side.joints[2]]!
        let upperLength = hypot((shoulder.x - elbow.x) * frame.width, (shoulder.y - elbow.y) * frame.height)
        let wristHeight = (wrist.y - shoulder.y) * frame.height / upperLength
        let a = action.angles
        let extended = smooth >= a.loweredAngleDegrees && wristHeight >= action.minimumOverheadWrist
        let contracted = smooth <= a.peakAngleDegrees && wristHeight <= action.maximumContractedWrist
        minimumConfidence = min(minimumConfidence, reading.confidence)
        estimator?.observe(angle: smooth, at: now - origin!)
        if let phaseAt, now - phaseAt > p.maximumCycleSeconds { reset(.cycleTimeout); return snapshot }
        switch snapshot.phase {
        case .waitingForExtension:
            if dwell(extended, now: now) { snapshot.phase = .lowered; dwellAt = nil }
        case .lowered:
            if smooth < a.departureAngleDegrees {
                pullAt = now; phaseAt = now; gapSeconds = 0; minimumConfidence = reading.confidence
                snapshot.phase = .raising; dwellAt = nil
            }
        case .raising:
            if dwell(contracted, now: now), let start = pullAt, let peak = dwellAt {
                guard peak - start - gapSeconds >= p.minimumMovementSeconds - 0.000001 else { reset(.movementTooShort); return snapshot }
                repetitions.append(CurlRepetition(liftSeconds: peak - start, holdSeconds: nil, lowerSeconds: nil,
                    completedAtSeconds: now - origin!, minimumConfidence: minimumConfidence,
                    trackingGapSeconds: gapSeconds > 0 ? gapSeconds : nil,
                    startedAtSeconds: start - origin!, peakAtSeconds: peak - origin!,
                    countingBasis: .contractedEndpoint, precedingReturn: pendingReturn))
                appendAttempt(start, now, .accepted, nil)
                pendingReturn = nil; pullAt = nil; dwellAt = nil; phaseAt = now
                snapshot.phase = .top
                estimator = PulldownReturnEstimator(policy: runtimePolicy?.eccentricPolicy ?? .init(), departure: a.returnAngleDegrees)
                estimator?.observe(angle: smooth, at: now - origin!)
            } else if extended { reset(.incompleteRange) }
        case .top:
            if smooth > a.returnAngleDegrees { snapshot.phase = .lowering; dwellAt = nil }
        case .lowering:
            if dwell(extended, now: now), let end = dwellAt {
                if let measurement = estimator?.finish(at: end - origin!) {
                    pendingReturn = PoseReturnObservation(repetitionIndex: repetitions.count - 1, measurement: measurement)
                }
                estimator = nil; phaseAt = nil; dwellAt = nil; snapshot.phase = .lowered
            } else if contracted { reset(.incompleteRange) }
        }
        return snapshot
    }

    private mutating func dwell(_ eligible: Bool, now: Double) -> Bool {
        if !eligible { dwellAt = nil; return false }
        if dwellAt == nil { dwellAt = now }
        return now - dwellAt! >= configuration.tracking.endpointDwellSeconds - 0.000001
    }
    private mutating func reject(_ reason: PoseFailureReason, at now: Double, immediate: Bool = false) {
        estimator?.markGap(); dwellAt = nil; snapshot.angle = nil; snapshot.failureReason = reason
        if !immediate, let acceptedAt, now - acceptedAt <= configuration.tracking.graceSeconds + 0.000001 {
            snapshot.trackingState = .grace
        } else { reset(reason) }
    }
    private mutating func reset(_ reason: PoseFailureReason) {
        if let start = pullAt, let now = lastTime {
            appendAttempt(start, now, reason == .incompleteRange || reason == .movementTooShort ? .observedBelowMinimum : .unobservable, reason)
        }
        if acceptedAt != nil {
            interruptions += 1; diagnostics.resetCounts[reason.rawValue, default: 0] += 1
        }
        acceptedAt = nil; anchor = nil; rawAngle = nil; angle = nil; dwellAt = nil; pullAt = nil; phaseAt = nil
        estimator = nil; pendingReturn = nil; gapSeconds = 0; minimumConfidence = 1
        snapshot.phase = .waitingForExtension; snapshot.trackingState = .lost; snapshot.failureReason = reason
    }
    mutating func interrupt() {
        reset(.explicitInterrupt); snapshot.quality = .discontinuous; snapshot.angle = nil
        if let lastTime {
            appendTrace(PoseTraceSample(elapsedSeconds: lastTime - (origin ?? lastTime), kind: "interrupt", width: 0, height: 0,
                people: 0, joints: [], quality: .discontinuous, phase: snapshot.phase,
                trackingState: .lost, reason: .explicitInterrupt, automaticCount: repetitions.count))
        }
    }
    private mutating func appendAttempt(_ start: Double, _ end: Double, _ outcome: PoseAttemptOutcome, _ reason: PoseFailureReason?) {
        guard attempts.count < 10000 else { droppedAttempts += 1; return }
        attempts.append(PoseAttemptEvent(startedAtSeconds: start - origin!, endedAtSeconds: end - origin!, outcome: outcome, reason: reason))
    }
    private mutating func record(_ frame: PoseFrame, reading: PoseReading, originalPeopleCount: Int?, selection: PoseSubjectSelection?) {
        let points = frame.people.count == 1 ? frame.people[0].points : [:]
        let joints = side.joints.compactMap { joint -> PoseTraceJoint? in
            guard let p = points[joint], p.isValid else { return nil }
            return PoseTraceJoint(joint: joint, x: p.x, y: p.y, confidence: p.confidence)
        }
        appendTrace(PoseTraceSample(elapsedSeconds: frame.timestamp - origin!, kind: "frame",
            width: frame.width.isFinite && (0...16384).contains(frame.width) ? frame.width : 0,
            height: frame.height.isFinite && (0...16384).contains(frame.height) ? frame.height : 0,
            people: min(10, frame.people.count), joints: joints, rawAngle: reading.angle, smoothedAngle: snapshot.angle,
            quality: snapshot.quality, phase: snapshot.phase, trackingState: snapshot.trackingState,
            reason: snapshot.failureReason, automaticCount: repetitions.count, originalPeopleCount: originalPeopleCount,
            selectedSubjectIndex: selection?.index, subjectState: selection?.state))
    }
    private mutating func appendTrace(_ sample: PoseTraceSample) {
        guard configuration.tracking.recordsTrace else { return }
        if diagnostics.samples.count < configuration.tracking.traceCapacity { diagnostics.samples.append(sample) }
        else { diagnostics.droppedSamples += 1 }
    }
}

/// A held pulldown peak can settle after an initial overshoot. Do not mistake that small rebound
/// for the return. On leaving the contracted region, replay only the latest monotonic suffix.
/// This uses already observed samples; detection time remains the later region-departure time.
struct PulldownReturnEstimator {
    let policy: PoseEccentricPolicy
    let departure: Double
    private var samples: [(angle: Double, time: Double)] = []
    private var estimator: PoseEccentricEstimator?
    private var confirmedAt: Double?
    private var gap = false
    var currentPhaseObservation: PoseReturnPhaseObservation {
        if gap { return .init(status: .unavailable, failure: .trackingGap) }
        guard var value = estimator?.currentPhaseObservation else { return .init(status: .waiting) }
        if let detected = value.detectedAtSeconds, let confirmedAt {
            value.detectedAtSeconds = max(detected, confirmedAt)
        }
        return value
    }
    init(policy: PoseEccentricPolicy, departure: Double) { self.policy = policy; self.departure = departure }
    mutating func markGap() { gap = true; estimator?.markGap() }
    mutating func observe(angle: Double, at time: Double) {
        if estimator != nil { estimator?.observe(angle: angle, at: time); return }
        if let previous = samples.last, time - previous.time > policy.maximumObservationGapSeconds { gap = true }
        guard samples.count < 6000 else { markGap(); return }
        samples.append((angle, time))
        guard angle > departure else { return }
        var first = samples.count - 1, low = angle
        while first > 0 {
            let earlier = samples[first - 1].angle
            if earlier - low > policy.noiseBandDegrees { break }
            low = min(low, earlier); first -= 1
        }
        estimator = PoseEccentricEstimator(policy: policy)
        for sample in samples[first...] { estimator?.observe(angle: sample.angle, at: sample.time) }
        if gap { estimator?.markGap() }
        confirmedAt = time; samples = []
    }
    func finish(at end: Double) -> PoseEccentricMeasurement {
        guard var result = estimator?.finish(at: end) else { return PoseEccentricMeasurement(status: gap ? .trackingGap : .insufficientMotion) }
        if result.status == .measured { result.detectedAtSeconds = max(result.detectedAtSeconds!, confirmedAt!) }
        return result
    }
}
