import Foundation

public enum Pose3DContractError: Error { case invalid }
public struct Pose3DTime: Codable, Equatable {
    public let value: Int64
    public let timescale: Int32
    public let epoch: Int64
    public init(value: Int64, timescale: Int32, epoch: Int64 = 0) { self.value = value; self.timescale = timescale; self.epoch = epoch }
    private enum CodingKeys: String, CodingKey { case value, timescale, epoch }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let v = Int64(try c.decode(String.self, forKey: .value)),
              let e = Int64(try c.decode(String.self, forKey: .epoch)) else { throw Pose3DContractError.invalid }
        value = v; epoch = e; timescale = try c.decode(Int32.self, forKey: .timescale)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(String(value), forKey: .value); try c.encode(timescale, forKey: .timescale); try c.encode(String(epoch), forKey: .epoch)
    }
    public func sameInstant(as other: Self) -> Bool {
        guard timescale > 0, other.timescale > 0, epoch == other.epoch else { return false }
        func reduced(_ t: Self) -> (Int64, Int64) {
            var a = t.value.magnitude, b = UInt64(t.timescale)
            while b != 0 { let r = a % b; a = b; b = r }
            let g = Int64(a); return (t.value / g, Int64(t.timescale) / g)
        }
        let a = reduced(self), b = reduced(other); return a.0 == b.0 && a.1 == b.1
    }
    public func isAfter(_ other: Self) -> Bool {
        guard timescale > 0, other.timescale > 0, epoch == other.epoch else { return false }
        let a = value.multipliedFullWidth(by: Int64(other.timescale))
        let b = other.value.multipliedFullWidth(by: Int64(timescale))
        return a.high == b.high ? a.low > b.low : a.high > b.high
    }
    public var seconds: Double { Double(value) / Double(timescale) }
}
public struct Pose3DFrameContext: Codable, Equatable {
    public let streamID: String
    public let segmentID: String
    public let frameIndex: Int
    public let pts: Pose3DTime?
    public let width: Int
    public let height: Int
    public let orientation: UInt32
    /// Describes source pixels, not an instruction to flip anatomical joint names.
    public let sourceMirrored: Bool
    public init(streamID: String, segmentID: String, frameIndex: Int, pts: Pose3DTime?, width: Int, height: Int,
                orientation: UInt32 = 1, sourceMirrored: Bool = false) {
        self.streamID = streamID; self.segmentID = segmentID; self.frameIndex = frameIndex; self.pts = pts
        self.width = width; self.height = height; self.orientation = orientation; self.sourceMirrored = sourceMirrored
    }
    public func validate() throws {
        guard !streamID.isEmpty, !segmentID.isEmpty, frameIndex >= 0,
              (1...16384).contains(width), (1...16384).contains(height), (1...8).contains(orientation),
              let pts, pts.timescale > 0 else { throw Pose3DContractError.invalid }
    }
    public func matchesFrame(_ other: Self) -> Bool {
        guard (try? validate()) != nil, (try? other.validate()) != nil else { return false }
        return streamID == other.streamID && segmentID == other.segmentID && frameIndex == other.frameIndex &&
        width == other.width && height == other.height && orientation == other.orientation && sourceMirrored == other.sourceMirrored &&
        pts.map { a in other.pts.map { a.sameInstant(as: $0) } ?? false } == true
    }
    /// Missing frame indices are diagnostic gaps, not interpolated observations.
    public func missingFrames(after previous: Self) throws -> Int {
        try validate(); try previous.validate()
        guard streamID == previous.streamID, segmentID == previous.segmentID,
              frameIndex > previous.frameIndex, let a = pts, let b = previous.pts,
              a.epoch == b.epoch, a.isAfter(b) else { throw Pose3DContractError.invalid }
        return frameIndex - previous.frameIndex - 1
    }
}
public enum Pose3DJointName: String, Codable, CaseIterable {
    case root, spine, centerShoulder, centerHead, topHead
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}
public struct Pose3DJoint: Codable, Equatable {
    public let name: Pose3DJointName
    /// Column-major Apple model transform, relative to root at hips; meters.
    public let modelTransform: [Double]
    public init(name: Pose3DJointName, modelTransform: [Double]) { self.name = name; self.modelTransform = modelTransform }
}
public enum Pose3DHeightSource: String, Codable { case reference, measured }
public struct Pose3DSkeleton: Codable, Equatable {
    public let coordinateSystem: String
    public let units: String
    public let matrixLayout: String
    public let joints: [Pose3DJoint]
    public let cameraOriginMatrix: [Double]
    public let bodyHeightMeters: Double
    public let heightSource: Pose3DHeightSource
    public init(joints: [Pose3DJoint], cameraOriginMatrix: [Double], bodyHeightMeters: Double, heightSource: Pose3DHeightSource) {
        coordinateSystem = "apple_vision_root_relative"; units = "meters"; matrixLayout = "column_major_4x4"
        self.joints = joints; self.cameraOriginMatrix = cameraOriginMatrix
        self.bodyHeightMeters = bodyHeightMeters; self.heightSource = heightSource
    }
    public func validate() throws {
        guard coordinateSystem == "apple_vision_root_relative", units == "meters", matrixLayout == "column_major_4x4", joints.count == 17, Set(joints.map(\.name)) == Set(Pose3DJointName.allCases),
              bodyHeightMeters.isFinite, bodyHeightMeters > 0,
              (heightSource != .reference || abs(bodyHeightMeters - 1.8) < 0.001),
              Self.validMatrix(cameraOriginMatrix), joints.allSatisfy({ Self.validMatrix($0.modelTransform) }) else {
            throw Pose3DContractError.invalid
        }
    }
    private static func validMatrix(_ values: [Double]) -> Bool {
        values.count == 16 && values.allSatisfy(\.isFinite) &&
        abs(values[3]) < 0.0001 && abs(values[7]) < 0.0001 && abs(values[11]) < 0.0001 && abs(values[15] - 1) < 0.0001
    }
}
public enum Pose3DOutcome: String, Codable { case observed, noObservation, unsupported, invalidInput, requestFailed, invalidOutput, dropped }
public struct Pose3DFailure: Codable, Equatable {
    public let domain: String
    public let code: Int
    public init(domain: String, code: Int) { self.domain = domain; self.code = code }
}
public struct Pose3DFrame: Codable, Equatable {
    public let schema: String
    public let algorithm: String
    public let context: Pose3DFrameContext
    public let requestedRevision: Int
    public let actualRevision: Int?
    public let outcome: Pose3DOutcome
    public let skeleton: Pose3DSkeleton?
    public let failure: Pose3DFailure?
    public let inferenceNanoseconds: UInt64
    public init(context: Pose3DFrameContext, requestedRevision: Int, actualRevision: Int? = nil, outcome: Pose3DOutcome,
                skeleton: Pose3DSkeleton? = nil, failure: Pose3DFailure? = nil, inferenceNanoseconds: UInt64 = 0) {
        schema = "fox.pose3d_frame.v1"; algorithm = "apple_vision_body_pose_3d"
        self.context = context; self.requestedRevision = requestedRevision; self.actualRevision = actualRevision
        self.outcome = outcome; self.skeleton = skeleton; self.failure = failure; self.inferenceNanoseconds = inferenceNanoseconds
    }
    public func validate() throws {
        guard schema == "fox.pose3d_frame.v1", algorithm == "apple_vision_body_pose_3d",
              requestedRevision > 0 || outcome == .invalidInput,
              actualRevision.map({ $0 > 0 }) ?? true else { throw Pose3DContractError.invalid }
        if outcome != .invalidInput { try context.validate() }
        switch outcome {
        case .observed:
            guard actualRevision == requestedRevision, failure == nil, let skeleton else { throw Pose3DContractError.invalid }
            try skeleton.validate()
        case .noObservation:
            guard actualRevision == requestedRevision, skeleton == nil, failure == nil else { throw Pose3DContractError.invalid }
        default:
            guard skeleton == nil, let failure, !failure.domain.isEmpty else { throw Pose3DContractError.invalid }
        }
    }
}
/// Matching source frames does not establish that 2D and 3D chose the same person.
public struct Pose3DComparison: Codable, Equatable {
    public let schema: String
    public let twoDArtifactID: String
    public let threeDArtifactID: String
    public let twoDContext: Pose3DFrameContext
    public let threeDContext: Pose3DFrameContext
    public var sameSourceFrame: Bool { twoDContext.matchesFrame(threeDContext) }
    public var subjectCorrespondence: String { "unverified" }
    public init(twoDArtifactID: String, twoD: Pose3DFrameContext, threeDArtifactID: String, threeD: Pose3DFrameContext) {
        schema = "fox.pose3d_comparison.v1"; self.twoDArtifactID = twoDArtifactID; self.threeDArtifactID = threeDArtifactID
        twoDContext = twoD; threeDContext = threeD
    }
}
