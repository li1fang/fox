import Foundation

public enum LateralTorsoReference: String, Codable { case sameSide = "same_side", freshOpposite = "fresh_opposite" }
public enum PoseAcquisitionMode: String, Codable {
    case regionOnly = "region_only"
    case singleReadyFallback = "single_ready_fallback_v1"
}

public struct CurlRecoveryPolicy: Codable, Equatable {
    public var schema = "fox.curl_recovery.v1"
    public var initialEndpointToleranceDegrees = 10.0
    public var wristOnlyGraceSeconds = 0.55
    public var maximumStableJointDrift = 0.06
    public init() {}
    public func validate() throws {
        guard schema == "fox.curl_recovery.v1", (0...10).contains(initialEndpointToleranceDegrees),
              (0...0.6).contains(wristOnlyGraceSeconds), (0.01...0.08).contains(maximumStableJointDrift)
        else { throw PoseConfigurationError.invalid }
    }
}

public struct PoseRuntimePolicy: Codable, Equatable {
    public var schema = "fox.pose_runtime_policy.v1"
    public var acquisitionMinX = 0.25
    public var acquisitionMaxX = 0.72
    public var acquisitionMinY = 0.50
    public var acquisitionMaxY = 0.95
    public var subjectConfidence = 0.35
    public var maximumSubjectJump = 0.14
    public var ambiguityMargin = 0.035
    public var retentionSeconds = 1.2
    public var countdownLossTolerance = 0.35
    public var endpointToleranceDegrees = 5.0
    public var curlReturnToleranceDegrees = 10.0
    public var returnEndpointDwellSeconds = 0.1
    public var loweredOcclusionSeconds = 1.0
    public var lateralTorsoReference: LateralTorsoReference?
    public var maximumTorsoObliquityDegrees: Double?
    // Missing in archived policies means the original region-only behavior.
    public var acquisitionMode: PoseAcquisitionMode?
    public var curlRecovery: CurlRecoveryPolicy?
    public var eccentricPolicy: PoseEccentricPolicy?
    public static let standard: Self = {
        guard let url = Bundle.module.url(forResource: "pose-runtime-defaults", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data),
              (try? value.validate()) != nil else { preconditionFailure("Invalid bundled pose runtime policy") }
        return value
    }()
    public init() {}
    public func validate() throws {
        try curlRecovery?.validate()
        try eccentricPolicy?.validate()
        guard schema == "fox.pose_runtime_policy.v1",
              (0...1).contains(acquisitionMinX), (acquisitionMinX...1).contains(acquisitionMaxX), acquisitionMaxX > acquisitionMinX,
              (0...1).contains(acquisitionMinY), (acquisitionMinY...1).contains(acquisitionMaxY), acquisitionMaxY > acquisitionMinY,
              (0.1...1).contains(subjectConfidence), (0.02...0.3).contains(maximumSubjectJump),
              (0.01...0.1).contains(ambiguityMargin), (0.3...2).contains(retentionSeconds),
              (0...0.5).contains(countdownLossTolerance), (0...15).contains(endpointToleranceDegrees),
              (0...10).contains(curlReturnToleranceDegrees),
              (0.1...0.5).contains(returnEndpointDwellSeconds),
              (0.3...2).contains(loweredOcclusionSeconds),
              maximumTorsoObliquityDegrees.map({ $0.isFinite && (5...30).contains($0) }) ?? true,
              lateralTorsoReference != .freshOpposite || maximumTorsoObliquityDegrees != nil else { throw PoseConfigurationError.invalid }
    }
}

public enum PoseSubjectState: String, Codable { case waiting, bound, occluded, ambiguous, lost }
public struct PoseSessionSettings: Codable, Equatable {
    public var schema = "fox.pose_session_settings.v1"
    public var configuration: PoseCounterConfiguration
    public var runtimePolicy: PoseRuntimePolicy
    public init(configuration: PoseCounterConfiguration, runtimePolicy: PoseRuntimePolicy) {
        self.configuration = configuration; self.runtimePolicy = runtimePolicy
    }
    public func validate() throws {
        guard schema == "fox.pose_session_settings.v1" else { throw PoseConfigurationError.invalid }
        try configuration.validate(); try runtimePolicy.validate()
        // The pulldown engine uses its own gates, not the legacy endpoint tolerance.
        // Validating an unused tolerance here would reject previously valid saved settings.
        for exercise in [VisionExercise.curl, .lateralRaise] {
            let angles = configuration.profile(for: exercise).cycleAngles(for: exercise)
            let tolerance = runtimePolicy.endpointToleranceDegrees + (exercise == .curl ?
                max(runtimePolicy.curlReturnToleranceDegrees, runtimePolicy.curlRecovery?.initialEndpointToleranceDegrees ?? 0) : 0)
            guard angles.bottom - tolerance > angles.departure else { throw PoseConfigurationError.invalid }
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    public static func migrating(configuration: PoseCounterConfiguration) throws -> Self {
        try configuration.validate()
        var settings = Self(configuration: configuration, runtimePolicy: .standard)
        if (try? settings.validate()) == nil {
            settings.runtimePolicy.endpointToleranceDegrees = 0
            settings.runtimePolicy.curlReturnToleranceDegrees = 0
            settings.runtimePolicy.curlRecovery?.initialEndpointToleranceDegrees = 0
        }
        try settings.validate(); return settings
    }
}

public struct PoseSubjectSelection {
    public var state: PoseSubjectState
    public var index: Int?
    public var anchor: PosePoint?
    public init(state: PoseSubjectState, index: Int? = nil, anchor: PosePoint? = nil) {
        self.state = state; self.index = index; self.anchor = anchor
    }
    public func selectedFrame(from frame: PoseFrame) -> PoseFrame {
        PoseFrame(timestamp: frame.timestamp, width: frame.width, height: frame.height,
                  people: index.flatMap { frame.people.indices.contains($0) ? [frame.people[$0]] : nil } ?? [])
    }
}

public struct PoseSubjectSelector {
    public let policy: PoseRuntimePolicy
    public private(set) var selection = PoseSubjectSelection(state: .waiting)
    private var anchor: PosePoint?
    private var lastSeen: Double?
    private var lastTimestamp: Double?
    private var scale: Double?
    public init(policy: PoseRuntimePolicy = .standard) {
        precondition((try? policy.validate()) != nil)
        self.policy = policy
    }
    public mutating func reset() { self = Self(policy: policy) }
    @discardableResult public mutating func process(_ frame: PoseFrame, side: ArmSide? = nil) -> PoseSubjectSelection {
        guard frame.timestamp.isFinite, lastTimestamp.map({ frame.timestamp > $0 }) ?? true else {
            return PoseSubjectSelection(state: selection.state)
        }
        lastTimestamp = frame.timestamp
        // Loss requires explicit rebind. A bystander must not inherit a departed subject's session.
        if selection.state == .lost { return selection }
        if let lastSeen, frame.timestamp - lastSeen > policy.retentionSeconds { selection = PoseSubjectSelection(state: .lost); return selection }
        let visibleCandidates = frame.people.enumerated().compactMap { index, person -> (Int, PosePoint, Double?)? in
            let shoulders = [person.points[.leftShoulder], person.points[.rightShoulder]].compactMap { $0 }.filter {
                $0.isValid && $0.confidence >= policy.subjectConfidence
            }
            guard !shoulders.isEmpty else { return nil }
            let point = PosePoint(x: shoulders.map(\.x).reduce(0,+) / Double(shoulders.count),
                                  y: shoulders.map(\.y).reduce(0,+) / Double(shoulders.count))
            let hips = [person.points[.leftHip], person.points[.rightHip]].compactMap { $0 }.filter { $0.isValid && $0.confidence >= policy.subjectConfidence }
            let size = hips.isEmpty ? nil : abs(point.y - hips.map(\.y).reduce(0,+) / Double(hips.count))
            return (index, point, size)
        }
        let candidates = visibleCandidates.filter { index, point, size in
            if let anchor {
                let distance = hypot(point.x - anchor.x, point.y - anchor.y)
                let ratio = size.flatMap { value in scale.map { value / max(0.01, $0) } }
                return distance <= policy.maximumSubjectJump && (ratio.map { (0.55...1.8).contains($0) } ?? true)
            }
            if policy.acquisitionMode == .singleReadyFallback, visibleCandidates.count == 1 {
                let candidate = PoseFrame(timestamp: frame.timestamp, width: frame.width, height: frame.height, people: [frame.people[index]])
                if (side.map { [$0] } ?? ArmSide.allCases).contains(where: {
                    Self.isReady(candidate, side: $0, confidence: policy.subjectConfidence)
                }) { return true }
            }
            return (policy.acquisitionMinX...policy.acquisitionMaxX).contains(point.x)
                && (policy.acquisitionMinY...policy.acquisitionMaxY).contains(point.y)
        }
        let reference = anchor ?? PosePoint(x: (policy.acquisitionMinX + policy.acquisitionMaxX) / 2,
                                            y: (policy.acquisitionMinY + policy.acquisitionMaxY) / 2)
        let ranked = candidates.map { candidate in (candidate, hypot(candidate.1.x - reference.x, candidate.1.y - reference.y)) }.sorted { $0.1 < $1.1 }
        guard let best = ranked.first else {
            selection = PoseSubjectSelection(state: anchor == nil ? .waiting : .occluded); return selection
        }
        if ranked.count > 1, ranked[1].1 - best.1 < policy.ambiguityMargin {
            selection = PoseSubjectSelection(state: .ambiguous); return selection
        }
        anchor = best.0.1; scale = best.0.2 ?? scale; lastSeen = frame.timestamp
        selection = PoseSubjectSelection(state: .bound, index: best.0.0, anchor: anchor)
        return selection
    }
    public static func isReady(_ frame: PoseFrame, side: ArmSide, confidence: Double = 0.35) -> Bool {
        guard frame.people.count == 1 else { return false }
        let points = frame.people[0].points
        // Starting is not a successful angle measurement: a side-view wrist may be briefly hidden.
        return [side.joints[0], side.joints[1]].allSatisfy { joint in
            points[joint].map { $0.isValid && $0.confidence >= confidence } ?? false
        }
    }
}
