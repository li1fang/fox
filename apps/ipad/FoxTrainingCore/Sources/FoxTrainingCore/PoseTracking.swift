import Foundation

public enum VisionExercise: String, CaseIterable, Codable {
    case curl, lateralRaise, latPulldown
    public var label: String { self == .latPulldown ? "高位下拉" : (self == .curl ? "哑铃弯举" : "哑铃侧平举") }
    public var algorithm: String { self == .latPulldown ? "lat_pulldown_2d_v1" : (self == .curl ? "curl_2d_v1" : "lateral_raise_2d_v1") }
    public var reliableAlgorithm: String { self == .latPulldown ? algorithm : (self == .curl ? "curl_2d_v2" : "lateral_raise_2d_v2") }
    public var currentAlgorithm: String { self == .latPulldown ? algorithm : (self == .curl ? "curl_2d_v3" : "lateral_raise_2d_v3") }
    public var recommendedBodyView: VisionBodyView { self == .latPulldown ? .back : (self == .curl ? .side : .front) }
    public func algorithm(runtimePolicy: PoseRuntimePolicy?) -> String {
        guard let runtimePolicy else { return reliableAlgorithm }
        if self == .curl && runtimePolicy.curlRecovery != nil { return "curl_2d_v4" }
        return self == .lateralRaise && runtimePolicy.lateralTorsoReference == .freshOpposite ? "lateral_raise_2d_v4" : currentAlgorithm
    }
    public var angleLabel: String { self == .lateralRaise ? "上臂外展角" : "肘角度" }
    public var guidance: String {
        self == .latPulldown ? "背面上半身 · 所选臂肩、肘、腕入镜" : (self == .curl ? "侧身面向镜头 · 所选臂靠近镜头" : "正面面向镜头 · 肩、肘、髋保持入镜")
    }
    public var waitingLabel: String { self == .latPulldown ? "等待上方伸展起点" : (self == .curl ? "等待手臂伸展" : "等待手臂放低") }
    public var visibilityLabel: String { self == .lateralRaise ? "所选侧肩、肘、髋不清晰" : "肩、肘、腕不清晰" }
}

public enum PoseJoint: String, CaseIterable, Codable {
    case nose, neck, root, leftEye, rightEye, leftEar, rightEar
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

public enum ArmSide: String, CaseIterable, Codable {
    case left, right
    public var label: String { self == .left ? "左臂" : "右臂" }
    public var joints: [PoseJoint] {
        self == .left ? [.leftShoulder, .leftElbow, .leftWrist] : [.rightShoulder, .rightElbow, .rightWrist]
    }
}

public struct PosePoint: Equatable {
    public var x: Double
    public var y: Double
    public var confidence: Double
    public init(x: Double, y: Double, confidence: Double = 1) {
        self.x = x; self.y = y; self.confidence = confidence
    }
    public var isValid: Bool {
        x.isFinite && y.isFinite && confidence.isFinite && (0...1).contains(x) && (0...1).contains(y) && (0...1).contains(confidence)
    }
}

public struct BodyPose {
    public var points: [PoseJoint: PosePoint]
    public init(points: [PoseJoint: PosePoint]) { self.points = points }
}

public struct PoseFrame {
    public var timestamp: Double
    public var width: Double
    public var height: Double
    public var people: [BodyPose]
    public init(timestamp: Double, width: Double, height: Double, people: [BodyPose]) {
        self.timestamp = timestamp; self.width = width; self.height = height; self.people = people
    }
}

public enum PoseQuality: String, Codable {
    case valid, noPerson, multiplePeople, lowConfidence, invalidFrame, discontinuous
    public var label: String {
        switch self {
        case .valid: return "关键点可见"
        case .noPerson: return "未检测到人"
        case .multiplePeople: return "画面中有多人"
        case .lowConfidence: return "肩、肘、腕不清晰"
        case .invalidFrame: return "等待有效画面"
        case .discontinuous: return "目标中断，等待重新伸展"
        }
    }
}

public struct PoseReading {
    public var quality: PoseQuality
    public var angle: Double?
    public var confidence: Double
    public var anchor: PosePoint?
    public var visiblePoints: Int
    public var failureReason: PoseFailureReason?
    public var usedTorsoFallback: Bool
    public init(quality: PoseQuality, angle: Double?, confidence: Double, anchor: PosePoint?, visiblePoints: Int,
                failureReason: PoseFailureReason? = nil, usedTorsoFallback: Bool = false) {
        self.quality = quality; self.angle = angle; self.confidence = confidence
        self.anchor = anchor; self.visiblePoints = visiblePoints
        self.failureReason = failureReason
        self.usedTorsoFallback = usedTorsoFallback
    }
}

public enum PoseGeometry {
    public static func inspect(_ frame: PoseFrame, side: ArmSide, exercise: VisionExercise = .curl,
                               configuration: PoseCounterConfiguration = .standard, tracking: Bool = false,
                               runtimePolicy: PoseRuntimePolicy? = nil) -> PoseReading {
        let empty = PoseReading(quality: .invalidFrame, angle: nil, confidence: 0, anchor: nil, visiblePoints: 0, failureReason: .invalidFrame)
        guard frame.timestamp.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, frame.width <= 16384, frame.height <= 16384 else { return empty }
        guard frame.people.count == 1 else {
            return PoseReading(quality: frame.people.isEmpty ? .noPerson : .multiplePeople, angle: nil, confidence: 0, anchor: nil, visiblePoints: 0,
                               failureReason: frame.people.isEmpty ? .noPerson : .multiplePeople)
        }
        let points = frame.people[0].points
        let visible = points.values.filter { $0.isValid && $0.confidence >= 0.35 }.count
        let profile = configuration.profile(for: exercise)
        let sameHip: PoseJoint = side == .left ? .leftHip : .rightHip
        var required = exercise != .lateralRaise ? side.joints : [side.joints[0], side.joints[1]]
            + (profile.requiresWrist ? [side.joints[2]] : [])
        let confidence = exercise == .latPulldown ? (tracking ? configuration.pulldown.trackingConfidence : configuration.pulldown.acquisitionConfidence) :
            (tracking ? configuration.tracking.trackingConfidence : configuration.tracking.acquisitionConfidence)
        let hipAvailable = points[sameHip].map { $0.isValid && $0.confidence >= confidence } ?? false
        let fallback = exercise == .lateralRaise && !hipAvailable && runtimePolicy?.lateralTorsoReference == .freshOpposite
        let opposite: ArmSide = side == .left ? .right : .left
        let otherHip: PoseJoint = side == .left ? .rightHip : .leftHip
        if exercise == .lateralRaise { required += fallback ? [opposite.joints[0], otherHip] : [sameHip] }
        for joint in required {
            guard let point = points[joint], point.isValid else {
                return PoseReading(quality: .lowConfidence, angle: nil, confidence: 0, anchor: nil, visiblePoints: visible, failureReason: .missingJoint)
            }
            guard point.confidence >= confidence else {
                return PoseReading(quality: .lowConfidence, angle: nil, confidence: point.confidence, anchor: nil, visiblePoints: visible, failureReason: .lowConfidence)
            }
        }
        let shoulder = points[side.joints[0]]!, elbow = points[side.joints[1]]!
        let origin = exercise != .lateralRaise ? elbow : shoulder
        let first = exercise != .lateralRaise ? shoulder : points[fallback ? otherHip : sameHip]!
        let second = exercise != .lateralRaise ? points[side.joints[2]]! : elbow
        let torsoOrigin = fallback ? points[opposite.joints[0]]! : origin
        let a = (x: (first.x - torsoOrigin.x) * frame.width, y: (first.y - torsoOrigin.y) * frame.height)
        let b = (x: (second.x - origin.x) * frame.width, y: (second.y - origin.y) * frame.height)
        let lengths = (hypot(a.x, a.y), hypot(b.x, b.y))
        if fallback {
            // A fresh opposite torso is a frontal-view proxy, never a carried-forward missing hip.
            let span = (x: (torsoOrigin.x - shoulder.x) * frame.width, y: (torsoOrigin.y - shoulder.y) * frame.height)
            let spanLength = hypot(span.x, span.y)
            let obliquity = abs(a.x * span.x + a.y * span.y) / max(0.000001, lengths.0 * spanLength)
            guard spanLength >= frame.height * configuration.tracking.minimumSegmentHeightFraction,
                  spanLength <= lengths.0 * 1.5,
                  obliquity <= sin((runtimePolicy!.maximumTorsoObliquityDegrees ?? 0) * .pi / 180),
                  a.y < 0 else {
                return PoseReading(quality: .lowConfidence, angle: nil, confidence: 0, anchor: nil, visiblePoints: visible, failureReason: .degenerateSegment)
            }
        }
        if exercise == .lateralRaise, profile.requiresWrist, let wrist = points[side.joints[2]],
           hypot((wrist.x - elbow.x) * frame.width, (wrist.y - elbow.y) * frame.height) < frame.height * configuration.tracking.minimumSegmentHeightFraction {
            return PoseReading(quality: .lowConfidence, angle: nil, confidence: 0, anchor: nil, visiblePoints: visible, failureReason: .degenerateSegment)
        }
        guard min(lengths.0, lengths.1) >= frame.height * configuration.tracking.minimumSegmentHeightFraction else {
            return PoseReading(quality: .lowConfidence, angle: nil, confidence: 0, anchor: nil, visiblePoints: visible, failureReason: .degenerateSegment)
        }
        let cosine = max(-1, min(1, (a.x * b.x + a.y * b.y) / (lengths.0 * lengths.1)))
        return PoseReading(quality: .valid, angle: acos(cosine) * 180 / .pi,
            confidence: required.compactMap { points[$0]?.confidence }.min() ?? 0, anchor: shoulder, visiblePoints: visible,
            usedTorsoFallback: fallback)
    }

    public static func project(_ point: PosePoint, imageWidth: Double, imageHeight: Double,
                               viewWidth: Double, viewHeight: Double, mirrored: Bool) -> (x: Double, y: Double) {
        guard min(imageWidth, imageHeight, viewWidth, viewHeight) > 0 else { return (0, 0) }
        let scale = min(viewWidth / imageWidth, viewHeight / imageHeight)
        let width = imageWidth * scale, height = imageHeight * scale
        return ((viewWidth - width) / 2 + (mirrored ? 1 - point.x : point.x) * width,
                (viewHeight - height) / 2 + (1 - point.y) * height)
    }
}

public enum CurlPhase: String, Codable {
    case waitingForExtension, lowered, raising, top, lowering
    public var label: String {
        switch self {
        case .waitingForExtension: return "等待手臂伸展"
        case .lowered: return "伸展"
        case .raising: return "上举"
        case .top: return "顶端停留"
        case .lowering: return "下放"
        }
    }
}

public struct CurlRepetition: Codable, Equatable {
    public var liftSeconds: Double
    public var holdSeconds: Double?
    public var lowerSeconds: Double?
    public var completedAtSeconds: Double
    public var minimumConfidence: Double
    public var trackingGapSeconds: Double? = nil
    public var startedAtSeconds: Double? = nil
    public var peakAtSeconds: Double? = nil
    public var loweredAtSeconds: Double? = nil
    public var geometryFallbackFrames: Int? = nil
    public var eccentric: PoseEccentricMeasurement? = nil
    public var countingBasis: PoseCountingBasis? = nil
    public var precedingReturn: PoseReturnObservation? = nil
}

public struct CurlSnapshot {
    public var quality: PoseQuality = .noPerson
    public var phase: CurlPhase = .waitingForExtension
    public var angle: Double?
    public var confidence: Double = 0
    public var trackingState: PoseTrackingState = .acquiring
    public var failureReason: PoseFailureReason?
    public var returnPhaseObservation: PoseReturnPhaseObservation?
    public init() {}
}

/// motion-strategy-curl / motion-strategy-lateral-raise describe these frozen cycle semantics.
/// Both commit after the observed return, not at the peak. Recoverable point loss may retain a
/// candidate but does not manufacture phase timing. Counting gates are not a form-quality score.
struct LegacyArmTracker {
    public let side: ArmSide
    public let exercise: VisionExercise
    public let configuration: PoseCounterConfiguration
    public let runtimePolicy: PoseRuntimePolicy?
    public private(set) var diagnostics: PoseCounterDiagnostics
    public private(set) var repetitions: [CurlRepetition] = []
    public private(set) var attempts: [PoseAttemptEvent] = []
    public private(set) var droppedAttempts = 0
    public private(set) var interruptions = 0
    public private(set) var snapshot = CurlSnapshot()
    private var lastTimestamp: Double?
    private var firstTimestamp: Double?
    private var lastAnchor: PosePoint?
    private var lastElbow: PosePoint?
    private var wristOnlyGrace = false
    private var lastRawAngle: Double?
    private var smoothedAngle: Double?
    private var wasValid = false
    private var extremeStarted: Double?
    private var liftStarted: Double?
    private var topStarted: Double?
    private var lowerStarted: Double?
    private var minimumConfidence = 1.0
    private var lastAcceptedTimestamp: Double?
    private var cycleGapSeconds = 0.0
    private var liftGapSeconds = 0.0
    private var lowerGapSeconds = 0.0
    private var cycleFallbackFrames = 0
    private var eccentricEstimator: PoseEccentricEstimator?
    var returnPhaseObservation: PoseReturnPhaseObservation? {
        [.raising, .top, .lowering].contains(snapshot.phase) ? eccentricEstimator?.currentPhaseObservation : nil
    }
    public init(side: ArmSide, exercise: VisionExercise = .curl, configuration: PoseCounterConfiguration = .standard, runtimePolicy: PoseRuntimePolicy? = nil) {
        precondition((try? configuration.validate()) != nil, "Invalid pose counter configuration")
        precondition(runtimePolicy == nil || (try? runtimePolicy!.validate()) != nil)
        if let runtimePolicy { precondition((try? PoseSessionSettings(configuration: configuration, runtimePolicy: runtimePolicy).validate()) != nil) }
        self.side = side; self.exercise = exercise; self.configuration = configuration
        self.runtimePolicy = runtimePolicy
        diagnostics = PoseCounterDiagnostics(configuration: configuration, runtimePolicy: runtimePolicy)
    }
    private var currentGrace: Double {
        if wristOnlyGrace { return max(configuration.tracking.graceSeconds, runtimePolicy?.curlRecovery?.wristOnlyGraceSeconds ?? 0) }
        return snapshot.phase == .lowered ? max(configuration.tracking.graceSeconds, runtimePolicy?.loweredOcclusionSeconds ?? 0) : configuration.tracking.graceSeconds
    }

    private func permitsWristGap(_ frame: PoseFrame, originalPeopleCount: Int?, selection: PoseSubjectSelection?) -> Bool {
        // Every missing frame must qualify; reacquiring an elbow cannot relabel a prior whole-body gap.
        if snapshot.trackingState == .grace && !wristOnlyGrace { return false }
        guard exercise == .curl, let policy = runtimePolicy?.curlRecovery, wasValid, topStarted != nil,
              frame.people.count == 1, (originalPeopleCount ?? 1) == 1,
              selection == nil || selection?.state == .bound,
              let shoulder = frame.people[0].points[side.joints[0]], let elbow = frame.people[0].points[side.joints[1]],
              let oldShoulder = lastAnchor, let oldElbow = lastElbow else { return false }
        let stable = [(shoulder, oldShoulder), (elbow, oldElbow)].allSatisfy {
            $0.0.isValid && $0.0.confidence >= configuration.tracking.trackingConfidence &&
            hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) <= min(policy.maximumStableJointDrift, configuration.tracking.maximumAnchorJump)
        }
        guard stable else { return false }
        let wrist = frame.people[0].points[side.joints[2]]
        let missing = wrist == nil || wrist?.isValid == false || (wrist?.confidence ?? 0) < configuration.tracking.trackingConfidence
        // A fresh good wrist can close an already-qualified gap, not open a new one.
        return missing || (wristOnlyGrace && snapshot.trackingState == .grace)
    }

    @discardableResult public mutating func process(_ frame: PoseFrame, originalPeopleCount: Int? = nil,
                                                  selection: PoseSubjectSelection? = nil) -> CurlSnapshot {
        guard frame.timestamp.isFinite, lastTimestamp.map({ frame.timestamp > $0 }) ?? true else { return snapshot }
        let delta = lastTimestamp.map { frame.timestamp - $0 } ?? 0
        lastTimestamp = frame.timestamp
        if firstTimestamp == nil { firstTimestamp = frame.timestamp }
        snapshot.failureReason = nil
        if delta > configuration.tracking.maximumFrameGapSeconds { discardCycle(reason: .frameGap) }
        wristOnlyGrace = permitsWristGap(frame, originalPeopleCount: originalPeopleCount, selection: selection)
        if snapshot.trackingState == .grace, let accepted = lastAcceptedTimestamp,
           frame.timestamp - accepted > currentGrace + 0.000001 {
            discardCycle(reason: .dropoutTimeout)
        }
        let reading = PoseGeometry.inspect(frame, side: side, exercise: exercise, configuration: configuration, tracking: wasValid, runtimePolicy: runtimePolicy)
        defer { record(frame, reading: reading, originalPeopleCount: originalPeopleCount, selection: selection) }
        snapshot.quality = reading.quality
        snapshot.angle = reading.angle
        snapshot.confidence = reading.confidence
        guard reading.quality == .valid, let raw = reading.angle, let anchor = reading.anchor else {
            if reading.quality == .multiplePeople || reading.quality == .invalidFrame {
                discardCycle(reason: reading.failureReason ?? .invalidFrame)
            } else { rejectTemporarily(reason: reading.failureReason ?? .lowConfidence, at: frame.timestamp) }
            return snapshot
        }
        let jumped = lastAnchor.map { hypot(anchor.x - $0.x, anchor.y - $0.y) > configuration.tracking.maximumAnchorJump } ?? false
        let angleJump = lastRawAngle.map { abs(raw - $0) > configuration.tracking.maximumAngleJumpDegrees } ?? false
        if jumped || angleJump {
            wristOnlyGrace = false
            rejectTemporarily(reason: jumped ? .anchorJump : .angleJump, at: frame.timestamp)
            snapshot.quality = .discontinuous
            return snapshot
        }
        let acceptedDelta = lastAcceptedTimestamp.map { frame.timestamp - $0 } ?? 0
        if snapshot.trackingState == .grace {
            diagnostics.recoveries += 1
            if liftStarted != nil {
                cycleGapSeconds += acceptedDelta
                if snapshot.phase == .raising { liftGapSeconds += acceptedDelta }
                if snapshot.phase == .lowering { lowerGapSeconds += acceptedDelta }
            }
        }
        lastAcceptedTimestamp = frame.timestamp
        lastAnchor = anchor
        lastElbow = frame.people.first?.points[side.joints[1]]
        wristOnlyGrace = false
        lastRawAngle = raw
        wasValid = true
        snapshot.trackingState = .tracking
        let alpha = acceptedDelta > 0 ? 1 - exp(-acceptedDelta / configuration.tracking.smoothingSeconds) : 1
        let angle = smoothedAngle.map { $0 + alpha * (raw - $0) } ?? raw
        smoothedAngle = angle
        snapshot.angle = angle
        minimumConfidence = min(minimumConfidence, reading.confidence)
        if liftStarted != nil && reading.usedTorsoFallback { cycleFallbackFrames += 1 }
        let now = frame.timestamp
        // Direction-normalize the signal; profiles and diagnostics retain anatomical angles.
        let cycleAngle = exercise == .curl ? angle : 180 - angle
        let angles = configuration.profile(for: exercise).cycleAngles(for: exercise)
        let bottom = max(angles.departure + 1, angles.bottom - (runtimePolicy?.endpointToleranceDegrees ?? 0))
        // Returning from an observed peak is different from initial acquisition. This is counting, not a form score.
        let returnBottom = exercise == .curl ? bottom - (runtimePolicy?.curlReturnToleranceDegrees ?? 0) : bottom
        let initialBottom = exercise == .curl ? bottom - (runtimePolicy?.curlRecovery?.initialEndpointToleranceDegrees ?? 0) : bottom
        let departure = angles.departure, peak = angles.peak, returnGate = angles.returning
        eccentricEstimator?.observe(angle: cycleAngle, at: now - (firstTimestamp ?? now))
        let policy = configuration.tracking
        if let liftStarted, now - liftStarted > policy.maximumCycleSeconds {
            discardCycle(reason: .cycleTimeout)
            snapshot.quality = .discontinuous
            return snapshot
        }
        switch snapshot.phase {
        case .waitingForExtension:
            if cycleAngle >= initialBottom {
                if extremeStarted == nil { extremeStarted = now }
                if now - extremeStarted! >= policy.endpointDwellSeconds - 0.000001 {
                    snapshot.phase = .lowered
                    extremeStarted = nil
                }
            } else { extremeStarted = nil }
        case .lowered:
            if cycleAngle < departure {
                liftStarted = now
                cycleGapSeconds = 0; liftGapSeconds = 0; lowerGapSeconds = 0
                minimumConfidence = reading.confidence
                cycleFallbackFrames = reading.usedTorsoFallback ? 1 : 0
                snapshot.phase = .raising
                eccentricEstimator = runtimePolicy?.eccentricPolicy.map { PoseEccentricEstimator(policy: $0) }
                eccentricEstimator?.observe(angle: cycleAngle, at: now - (firstTimestamp ?? now))
            }
        case .raising:
            if cycleAngle <= peak {
                if extremeStarted == nil { extremeStarted = now }
                if now - extremeStarted! >= policy.endpointDwellSeconds - 0.000001 {
                    topStarted = extremeStarted
                    extremeStarted = nil
                    snapshot.phase = .top
                }
            } else {
                extremeStarted = nil
                if cycleAngle >= bottom { discardCycle(reason: .incompleteRange) }
            }
        case .top:
            if cycleAngle > returnGate {
                lowerStarted = now
                snapshot.phase = .lowering
            }
        case .lowering:
            if cycleAngle >= returnBottom {
                if extremeStarted == nil { extremeStarted = now }
                if now - extremeStarted! >= (runtimePolicy?.returnEndpointDwellSeconds ?? policy.endpointDwellSeconds) - 0.000001 {
                    if let lift = liftStarted, let top = topStarted, let lower = lowerStarted,
                       top - lift - liftGapSeconds >= policy.minimumMovementSeconds - 0.000001,
                       extremeStarted! - lower - lowerGapSeconds >= policy.minimumMovementSeconds - 0.000001 {
                        repetitions.append(CurlRepetition(liftSeconds: top - lift, holdSeconds: lower - top,
                            lowerSeconds: extremeStarted! - lower, completedAtSeconds: now - (firstTimestamp ?? now),
                            minimumConfidence: minimumConfidence, trackingGapSeconds: cycleGapSeconds > 0 ? cycleGapSeconds : nil,
                            startedAtSeconds: runtimePolicy == nil ? nil : lift - (firstTimestamp ?? now),
                            peakAtSeconds: runtimePolicy == nil ? nil : top - (firstTimestamp ?? now),
                            loweredAtSeconds: runtimePolicy == nil ? nil : extremeStarted! - (firstTimestamp ?? now),
                            geometryFallbackFrames: cycleFallbackFrames > 0 ? cycleFallbackFrames : nil,
                            eccentric: eccentricEstimator?.finish(at: extremeStarted! - (firstTimestamp ?? now))))
                        appendAttempt(started: lift, ended: now, outcome: .accepted, reason: nil)
                    } else {
                        discardCycle(reason: .movementTooShort)
                        return snapshot
                    }
                    resetPhase()
                    snapshot.phase = .lowered
                }
            } else {
                extremeStarted = nil
                if cycleAngle <= peak { discardCycle(reason: .incompleteRange) }
            }
        }
        return snapshot
    }

    public mutating func interrupt() {
        discardCycle(reason: .explicitInterrupt)
        if let timestamp = lastTimestamp {
            appendTrace(PoseTraceSample(elapsedSeconds: timestamp - (firstTimestamp ?? timestamp), kind: "interrupt", width: 0,
                height: 0, people: 0, joints: [], rawAngle: nil, smoothedAngle: nil, quality: .discontinuous,
                phase: snapshot.phase, trackingState: .lost, reason: .explicitInterrupt, automaticCount: repetitions.count))
        }
        snapshot.quality = .discontinuous
        snapshot.angle = nil
    }

    private mutating func rejectTemporarily(reason: PoseFailureReason, at timestamp: Double) {
        eccentricEstimator?.markGap()
        snapshot.failureReason = reason
        snapshot.angle = nil
        // Missing observations cannot establish a continuous endpoint dwell.
        extremeStarted = nil
        if wasValid, let last = lastAcceptedTimestamp,
           timestamp - last <= currentGrace + 0.000001 {
            snapshot.trackingState = .grace
        } else if wasValid {
            discardCycle(reason: .dropoutTimeout)
        }
    }

    private mutating func discardCycle(reason: PoseFailureReason) {
        if let started = liftStarted, let ended = lastTimestamp {
            let belowMinimum = reason == .incompleteRange || reason == .movementTooShort
            appendAttempt(started: started, ended: ended, outcome: belowMinimum ? .observedBelowMinimum : .unobservable, reason: reason)
        }
        if wasValid {
            interruptions += 1
            diagnostics.resetCounts[reason.rawValue, default: 0] += 1
        }
        snapshot.failureReason = reason
        snapshot.trackingState = .lost
        wasValid = false
        lastAcceptedTimestamp = nil
        lastAnchor = nil
        lastElbow = nil; wristOnlyGrace = false
        lastRawAngle = nil
        smoothedAngle = nil
        resetPhase()
    }

    private mutating func appendAttempt(started: Double, ended: Double, outcome: PoseAttemptOutcome, reason: PoseFailureReason?) {
        guard attempts.count < 10000 else { droppedAttempts += 1; return }
        let origin = firstTimestamp ?? started
        attempts.append(PoseAttemptEvent(startedAtSeconds: started - origin, endedAtSeconds: ended - origin,
            outcome: outcome, reason: reason))
    }

    private mutating func resetPhase() {
        snapshot.phase = .waitingForExtension
        extremeStarted = nil; liftStarted = nil; topStarted = nil; lowerStarted = nil
        minimumConfidence = 1
        cycleGapSeconds = 0; liftGapSeconds = 0; lowerGapSeconds = 0
        cycleFallbackFrames = 0
        eccentricEstimator = nil
    }

    private mutating func record(_ frame: PoseFrame, reading: PoseReading, originalPeopleCount: Int?, selection: PoseSubjectSelection?) {
        var selected = side.joints + [side == .left ? PoseJoint.leftHip : .rightHip]
        if exercise == .lateralRaise && runtimePolicy?.lateralTorsoReference == .freshOpposite {
            selected += [side == .left ? .rightShoulder : .leftShoulder, side == .left ? .rightHip : .leftHip]
        }
        let points = frame.people.count == 1 ? frame.people[0].points : [:]
        let joints = selected.compactMap { joint -> PoseTraceJoint? in
            guard let point = points[joint], point.isValid else { return nil }
            return PoseTraceJoint(joint: joint, x: point.x, y: point.y, confidence: point.confidence)
        }
        appendTrace(PoseTraceSample(elapsedSeconds: frame.timestamp - (firstTimestamp ?? frame.timestamp), kind: "frame",
            width: frame.width.isFinite && (0...16384).contains(frame.width) ? frame.width : 0,
            height: frame.height.isFinite && (0...16384).contains(frame.height) ? frame.height : 0,
            people: min(10, frame.people.count), joints: joints, rawAngle: reading.angle, smoothedAngle: snapshot.angle,
            quality: snapshot.quality, phase: snapshot.phase, trackingState: snapshot.trackingState,
            reason: snapshot.failureReason, automaticCount: repetitions.count,
            originalPeopleCount: originalPeopleCount, selectedSubjectIndex: selection?.index, subjectState: selection?.state,
            usedTorsoFallback: reading.usedTorsoFallback ? true : nil))
    }

    private mutating func appendTrace(_ sample: PoseTraceSample) {
        guard configuration.tracking.recordsTrace else { return }
        guard diagnostics.samples.count < configuration.tracking.traceCapacity else { diagnostics.droppedSamples += 1; return }
        diagnostics.samples.append(sample)
    }
}
