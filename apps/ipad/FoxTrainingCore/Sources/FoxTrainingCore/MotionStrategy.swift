import Foundation

/// Descriptive contract for an implemented algorithm, not an executable rule language.
/// Defaults own numeric thresholds; these resources own their meaning and supported observation conditions.
public struct MotionStrategy: Codable, Equatable {
    public struct Counting: Codable, Equatable {
        public let commit: String
        public let terminal: String
        public let rangeMeaning: String
    }
    public struct Phase: Codable, Equatable {
        public let kind: String
        public let end: String
        public let publication: String
        public let lastRepetition: String
        public let fullEccentricComparison: Bool
    }
    public struct Parameters: Codable, Equatable {
        public let configuration: String
        public let profile: String
        public let runtime: String
    }
    public let schema: String
    public let id: String
    public let version: Int
    public let exercise: VisionExercise
    public let algorithm: String
    public let bodyView: VisionBodyView
    public let provider: String
    public let coordinateSpace: String
    public let preparationJoints: [String]
    public let countingJoints: [String]
    public let alternativeGeometry: String
    public let counting: Counting
    public let recovery: [String: String]
    public let phase: Phase
    public let parameters: Parameters
    public let limitations: [String]
    public let contractTests: [String]

    public static func load(_ exercise: VisionExercise) throws -> Self {
        let name = exercise == .latPulldown ? "lat-pulldown" : (exercise == .curl ? "curl" : "lateral-raise")
        guard let url = Bundle.module.url(forResource: "motion-strategy-\(name)", withExtension: "json") else { throw PoseConfigurationError.invalid }
        let strategy = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try strategy.validate()
        return strategy
    }

    public func validate() throws {
        let pulldown = exercise == .latPulldown
        guard schema == "fox.motion_strategy.v1", version == 1, !id.isEmpty,
              algorithm == exercise.algorithm(runtimePolicy: .standard), bodyView == exercise.recommendedBodyView,
              provider == "apple_vision_2d", coordinateSpace == "normalized_image_y_up_pixel_aspect_corrected",
              preparationJoints == ["selected.shoulder", "selected.elbow"],
              countingJoints == ["selected.shoulder", "selected.elbow", exercise == .lateralRaise ? "selected.hip" : "selected.wrist"],
              alternativeGeometry == (exercise == .lateralRaise ? "fresh_opposite_torso_with_obliquity_guard" : "none"),
              counting.commit == (pulldown ? "contracted_endpoint" : "completed_cycle"),
              counting.terminal == (pulldown ? "peak_without_return" : "requires_return"),
              counting.rangeMeaning == "counting_gate_not_form_score",
              phase.kind == "visual_angular_return", phase.end == "counting_gate", !phase.fullEccentricComparison,
              phase.publication == (pulldown ? "following_accepted_peak" : "same_cycle"),
              phase.lastRepetition == (pulldown ? "excluded" : "only_observed"),
              parameters.configuration == "pose-counter-defaults.json", parameters.profile == exercise.rawValue,
              parameters.runtime == "pose-runtime-defaults.json",
              recovery["timingAfterGap"] == "unmeasured",
              recovery["longGap"] == "discard_unfinished_preserve_count",
              !limitations.isEmpty, !contractTests.isEmpty else { throw PoseConfigurationError.invalid }
    }
}
