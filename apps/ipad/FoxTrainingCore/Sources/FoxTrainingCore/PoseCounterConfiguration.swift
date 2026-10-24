import Foundation

public struct PoseTrackingPolicy: Codable, Equatable {
    public var acquisitionConfidence: Double
    public var trackingConfidence: Double
    public var graceSeconds: Double
    public var maximumFrameGapSeconds: Double
    public var maximumAnchorJump: Double
    public var maximumAngleJumpDegrees: Double
    public var minimumSegmentHeightFraction: Double
    public var smoothingSeconds: Double
    public var endpointDwellSeconds: Double
    public var minimumMovementSeconds: Double
    public var maximumCycleSeconds: Double
    public var recordsTrace: Bool
    public var traceCapacity: Int
}

public struct PoseExerciseProfile: Codable, Equatable {
    public var loweredAngleDegrees: Double
    public var departureAngleDegrees: Double
    public var peakAngleDegrees: Double
    public var returnAngleDegrees: Double
    public var requiresWrist: Bool

    func cycleAngles(for exercise: VisionExercise) -> (bottom: Double, departure: Double, peak: Double, returning: Double) {
        func transform(_ angle: Double) -> Double { exercise == .lateralRaise ? 180 - angle : angle }
        return (transform(loweredAngleDegrees), transform(departureAngleDegrees), transform(peakAngleDegrees), transform(returnAngleDegrees))
    }
}

public struct PoseCounterConfiguration: Codable, Equatable {
    public var schema: String
    public var name: String
    public var tracking: PoseTrackingPolicy
    public var curl: PoseExerciseProfile
    public var lateralRaise: PoseExerciseProfile
    public var latPulldown: LatPulldownPolicy? = nil
    public var pulldown: LatPulldownPolicy { latPulldown ?? .init() }

    public static let standard: Self = {
        do {
            let url = Bundle.module.url(forResource: "pose-counter-defaults", withExtension: "json")!
            return try decode(Data(contentsOf: url))
        } catch { preconditionFailure("Invalid bundled pose counter configuration: \(error)") }
    }()

    // Historical validation must not drift when the editable v2 defaults change.
    public static let legacy = Self(schema: "fox.pose_counter_configuration.v1", name: "legacy-strict-v1",
        tracking: PoseTrackingPolicy(acquisitionConfidence: 0.55, trackingConfidence: 0.55, graceSeconds: 0,
            maximumFrameGapSeconds: 0.40, maximumAnchorJump: 0.22, maximumAngleJumpDegrees: 70,
            minimumSegmentHeightFraction: 0.025, smoothingSeconds: 0.08, endpointDwellSeconds: 0.18,
            minimumMovementSeconds: 0.20, maximumCycleSeconds: 20, recordsTrace: true, traceCapacity: 6000),
        curl: PoseExerciseProfile(loweredAngleDegrees: 150, departureAngleDegrees: 130, peakAngleDegrees: 70,
                                  returnAngleDegrees: 90, requiresWrist: true),
        lateralRaise: PoseExerciseProfile(loweredAngleDegrees: 20, departureAngleDegrees: 35, peakAngleDegrees: 75,
                                          returnAngleDegrees: 60, requiresWrist: true))

    public func profile(for exercise: VisionExercise) -> PoseExerciseProfile {
        switch exercise {
        case .curl: return curl
        case .lateralRaise: return lateralRaise
        case .latPulldown: return pulldown.angles
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        let configuration = try JSONDecoder().decode(Self.self, from: data)
        try configuration.validate()
        return configuration
    }

    public func validate() throws {
        try pulldown.validate()
        let p = tracking
        guard schema == "fox.pose_counter_configuration.v1", !name.isEmpty, name.count <= 80,
              (0.1...1).contains(p.trackingConfidence), (p.trackingConfidence...1).contains(p.acquisitionConfidence),
              (0...0.5).contains(p.graceSeconds), (max(0.1, p.graceSeconds)...1).contains(p.maximumFrameGapSeconds),
              (0.01...0.5).contains(p.maximumAnchorJump), (10...180).contains(p.maximumAngleJumpDegrees),
              (0.001...0.1).contains(p.minimumSegmentHeightFraction), (0.001...1).contains(p.smoothingSeconds),
              (0.05...1).contains(p.endpointDwellSeconds), (0.1...2).contains(p.minimumMovementSeconds),
              (2...60).contains(p.maximumCycleSeconds), (1...10000).contains(p.traceCapacity), curl.requiresWrist else {
            throw PoseConfigurationError.invalid
        }
        for exercise in VisionExercise.allCases {
            let angles = profile(for: exercise).cycleAngles(for: exercise)
            guard [angles.bottom, angles.departure, angles.peak, angles.returning].allSatisfy({ $0.isFinite && (0...180).contains($0) }),
                  angles.peak < angles.returning, angles.returning < angles.departure, angles.departure < angles.bottom else {
                throw PoseConfigurationError.invalid
            }
        }
    }
}

public enum PoseConfigurationError: LocalizedError {
    case invalid
    public var errorDescription: String? { "参数无效：请检查范围、角度顺序和时间设置。" }
}

public final class PoseConfigurationStore {
    public let fileURL: URL
    public private(set) var configuration: PoseCounterConfiguration
    private let writer: (Data, URL) throws -> Void
    public init(fileURL: URL, writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.fileURL = fileURL; self.writer = writer
        configuration = FileManager.default.fileExists(atPath: fileURL.path)
            ? try PoseCounterConfiguration.decode(Data(contentsOf: fileURL)) : .standard
    }
    public func save(_ value: PoseCounterConfiguration) throws {
        try value.validate()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer(LocalTrainingRepository.encoder().encode(value), fileURL)
        configuration = value
    }

    public static func replaceUnreadable(fileURL: URL, with value: PoseCounterConfiguration) throws -> PoseConfigurationStore {
        try value.validate()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let backup = fileURL.appendingPathExtension("invalid-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: fileURL, to: backup)
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LocalTrainingRepository.encoder().encode(value).write(to: fileURL, options: .atomic)
        return try PoseConfigurationStore(fileURL: fileURL)
    }
}
