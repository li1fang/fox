import Foundation

public enum PoseTrackingState: String, Codable { case acquiring, tracking, grace, lost }
public enum PoseFailureReason: String, Codable {
    case noPerson, multiplePeople, invalidFrame, missingJoint, lowConfidence, degenerateSegment
    case frameGap, anchorJump, angleJump, dropoutTimeout, incompleteRange, cycleTimeout, movementTooShort, explicitInterrupt
    public var label: String {
        switch self {
        case .noPerson: return "未检测到人"
        case .multiplePeople: return "画面中有多人"
        case .invalidFrame: return "画面无效"
        case .missingJoint: return "关节点缺失"
        case .lowConfidence: return "关节点置信度不足"
        case .degenerateSegment: return "关节投影重合"
        case .frameGap: return "帧间隔过长"
        case .anchorJump: return "目标位置跳变"
        case .angleJump: return "角度跳变"
        case .dropoutTimeout: return "追踪缺失超时"
        case .incompleteRange: return "未观测到完整幅度"
        case .cycleTimeout: return "动作循环超时"
        case .movementTooShort: return "有效观测时长不足"
        case .explicitInterrupt: return "计数暂停或相机中断"
        }
    }
}

public struct PoseTraceJoint: Codable, Equatable {
    public var joint: PoseJoint
    public var x: Double
    public var y: Double
    public var confidence: Double
    public init(joint: PoseJoint, x: Double, y: Double, confidence: Double) {
        self.joint = joint; self.x = x; self.y = y; self.confidence = confidence
    }
}

public struct PoseTraceSample: Codable, Equatable {
    public var elapsedSeconds: Double
    public var kind: String
    public var width: Double
    public var height: Double
    public var people: Int
    public var joints: [PoseTraceJoint]
    public var rawAngle: Double?
    public var smoothedAngle: Double?
    public var quality: PoseQuality
    public var phase: CurlPhase
    public var trackingState: PoseTrackingState
    public var reason: PoseFailureReason?
    public var automaticCount: Int
    public var originalPeopleCount: Int? = nil
    public var selectedSubjectIndex: Int? = nil
    public var subjectState: PoseSubjectState? = nil
    public var usedTorsoFallback: Bool? = nil

    var frame: PoseFrame {
        let points = Dictionary(uniqueKeysWithValues: joints.map { ($0.joint, PosePoint(x: $0.x, y: $0.y, confidence: $0.confidence)) })
        return PoseFrame(timestamp: elapsedSeconds, width: width, height: height,
                         people: Array(repeating: BodyPose(points: points), count: people))
    }
}

public struct PoseCounterDiagnostics: Codable, Equatable {
    public var schema = "fox.pose_counter_diagnostics.v1"
    public var configuration: PoseCounterConfiguration
    public var runtimePolicy: PoseRuntimePolicy?
    public var resetCounts: [String: Int] = [:]
    public var recoveries = 0
    public var droppedSamples = 0
    public var samples: [PoseTraceSample] = []
    public init(configuration: PoseCounterConfiguration, runtimePolicy: PoseRuntimePolicy? = nil) { self.configuration = configuration; self.runtimePolicy = runtimePolicy }

    public func validate(side: ArmSide) throws {
        try configuration.validate()
        try runtimePolicy?.validate()
        if let runtimePolicy { try PoseSessionSettings(configuration: configuration, runtimePolicy: runtimePolicy).validate() }
        guard schema == "fox.pose_counter_diagnostics.v1", recoveries >= 0, droppedSamples >= 0,
              samples.count <= configuration.tracking.traceCapacity,
              configuration.tracking.recordsTrace || (samples.isEmpty && droppedSamples == 0),
              resetCounts.allSatisfy({ PoseFailureReason(rawValue: $0.key) != nil && $0.value >= 0 }) else {
            throw VisionTrialError.invalidReport
        }
        var permitted = Set(side.joints + [side == .left ? .leftHip : .rightHip])
        if runtimePolicy?.lateralTorsoReference == .freshOpposite {
            permitted.formUnion([side == .left ? .rightShoulder : .leftShoulder, side == .left ? .rightHip : .leftHip])
        }
        var previous = -1.0
        for sample in samples {
            guard sample.elapsedSeconds.isFinite, sample.elapsedSeconds >= 0, sample.elapsedSeconds >= previous,
                  ["frame", "interrupt"].contains(sample.kind),
                  [sample.width, sample.height].allSatisfy({ $0.isFinite && (0...16384).contains($0) }),
                  (0...10).contains(sample.people), (0...10000).contains(sample.automaticCount),
                  [sample.rawAngle, sample.smoothedAngle].compactMap({ $0 }).allSatisfy({ $0.isFinite && (0...180).contains($0) }),
                  Set(sample.joints.map(\.joint)).count == sample.joints.count,
                  sample.usedTorsoFallback != true || runtimePolicy?.lateralTorsoReference == .freshOpposite,
                  sample.joints.allSatisfy({ permitted.contains($0.joint) && PosePoint(x: $0.x, y: $0.y, confidence: $0.confidence).isValid }),
                  sample.kind != "interrupt" || (sample.joints.isEmpty && sample.reason == .explicitInterrupt) else {
                throw VisionTrialError.invalidReport
            }
            if let count = sample.originalPeopleCount {
                guard runtimePolicy != nil, (0...10).contains(count), count >= sample.people,
                      sample.selectedSubjectIndex.map({ (0..<count).contains($0) && sample.people == 1 && sample.subjectState == .bound }) ?? true else {
                    throw VisionTrialError.invalidReport
                }
            } else if sample.selectedSubjectIndex != nil || sample.subjectState != nil { throw VisionTrialError.invalidReport }
            previous = sample.elapsedSeconds
        }
    }
}

public enum PoseReplayError: LocalizedError {
    case unavailable, truncated
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "报告没有逐帧数值记录，不能回放。旧报告不能补造观测。"
        case .truncated: return "数值记录已截断，不能作为完整回放比较。"
        }
    }
}

public enum PoseReplay {
    public static func replay(_ trial: VisionTrial, configuration: PoseCounterConfiguration? = nil,
                              runtimePolicy: PoseRuntimePolicy? = nil) throws -> CurlTracker {
        try trial.validate()
        guard let evidence = trial.counterDiagnostics, evidence.configuration.tracking.recordsTrace,
              evidence.samples.contains(where: { $0.kind == "frame" }) else { throw PoseReplayError.unavailable }
        guard evidence.droppedSamples == 0 else { throw PoseReplayError.truncated }
        let settings = configuration ?? evidence.configuration
        try settings.validate()
        let runtime = runtimePolicy ?? evidence.runtimePolicy
        if let runtime { try PoseSessionSettings(configuration: settings, runtimePolicy: runtime).validate() }
        var tracker = CurlTracker(side: trial.arm, exercise: trial.resolvedExercise, configuration: settings, runtimePolicy: runtime)
        for sample in evidence.samples {
            if sample.kind == "interrupt" { tracker.interrupt() } else {
                tracker.process(sample.frame, originalPeopleCount: sample.originalPeopleCount,
                    selection: sample.subjectState.map { PoseSubjectSelection(state: $0, index: sample.selectedSubjectIndex) })
            }
        }
        return tracker
    }
}
