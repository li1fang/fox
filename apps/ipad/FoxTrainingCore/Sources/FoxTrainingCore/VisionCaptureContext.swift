import Foundation

public enum VisionBodyView: String, CaseIterable, Codable {
    case unknown, front, side, back, mixed
    public var label: String {
        switch self {
        case .unknown: return "未标注"
        case .front: return "正面"
        case .side: return "侧面"
        case .back: return "背面"
        case .mixed: return "混合机位"
        }
    }
}

public enum VisionScreenOrientation: String, Codable {
    case unknown, portrait, portraitUpsideDown, landscapeLeft, landscapeRight
}

public enum VisionMotionStatus: String, Codable { case available, unavailable, failed, fixture }
public enum VisionMotionSource: String, Codable { case coreMotion, fixture }

public struct VisionDevicePose: Codable, Equatable {
    public var source: VisionMotionSource
    public var gravityX: Double
    public var gravityY: Double
    public var gravityZ: Double
    public var screenInclinationDegrees: Double
    public var cameraElevationDegrees: Double

    public static func measure(gravityX x: Double, gravityY y: Double, gravityZ z: Double,
                               frontCamera: Bool, source: VisionMotionSource) -> VisionDevicePose? {
        guard [x, y, z].allSatisfy(\.isFinite) else { return nil }
        let magnitude = sqrt(x * x + y * y + z * z)
        guard (0.5...1.5).contains(magnitude) else { return nil }
        let normalizedZ = max(-1, min(1, z / magnitude))
        // Device +Z points out of the screen; the back camera looks in the opposite direction.
        return VisionDevicePose(source: source, gravityX: x, gravityY: y, gravityZ: z,
            screenInclinationDegrees: acos(-normalizedZ) * 180 / .pi,
            cameraElevationDegrees: (frontCamera ? -1 : 1) * asin(normalizedZ) * 180 / .pi)
    }

    public func validate(frontCamera: Bool) throws {
        guard let measured = Self.measure(gravityX: gravityX, gravityY: gravityY, gravityZ: gravityZ,
                frontCamera: frontCamera, source: source),
              screenInclinationDegrees.isFinite, cameraElevationDegrees.isFinite,
              abs(screenInclinationDegrees - measured.screenInclinationDegrees) < 0.000001,
              abs(cameraElevationDegrees - measured.cameraElevationDegrees) < 0.000001 else { throw VisionTrialError.invalidReport }
    }
}

public struct VisionFraming: Codable, Equatable {
    public var visibleBodyPoints: Int
    public var observedWidthFraction: Double
    public var observedHeightFraction: Double
    public var torsoHeightFraction: Double?
    public var shoulderWidthFraction: Double?
    public var nearImageEdge: Bool

    public static func measure(_ frame: PoseFrame) -> VisionFraming? {
        guard frame.timestamp.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, frame.people.count == 1 else { return nil }
        let bodyJoints: Set<PoseJoint> = [.neck, .root, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
            .leftWrist, .rightWrist, .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
        let points = frame.people[0].points.filter { bodyJoints.contains($0.key) && $0.value.isValid && $0.value.confidence >= 0.55 }
        guard points.count >= 4 else { return nil }
        let xs = points.values.map(\.x), ys = points.values.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let torso = points[.neck].flatMap { neck in points[.root].map { abs(neck.y - $0.y) } }
        let shoulders = points[.leftShoulder].flatMap { left in points[.rightShoulder].map { abs(left.x - $0.x) } }
        return VisionFraming(visibleBodyPoints: points.count, observedWidthFraction: maxX - minX,
            observedHeightFraction: maxY - minY, torsoHeightFraction: torso, shoulderWidthFraction: shoulders,
            nearImageEdge: minX <= 0.03 || maxX >= 0.97 || minY <= 0.03 || maxY >= 0.97)
    }

    public func validate() throws {
        guard (4...14).contains(visibleBodyPoints),
              [observedWidthFraction, observedHeightFraction].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [torsoHeightFraction, shoulderWidthFraction].compactMap({ $0 }).allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { throw VisionTrialError.invalidReport }
    }
}

public struct VisionCameraGeometry: Codable, Equatable {
    public var deviceType: String
    public var zoomFactor: Double
    public var reportedFormatFieldOfViewDegrees: Double
    public init(deviceType: String, zoomFactor: Double, reportedFormatFieldOfViewDegrees: Double) {
        self.deviceType = deviceType; self.zoomFactor = zoomFactor
        self.reportedFormatFieldOfViewDegrees = reportedFormatFieldOfViewDegrees
    }
    public func validate() throws {
        guard !deviceType.isEmpty, zoomFactor.isFinite, zoomFactor > 0,
              reportedFormatFieldOfViewDegrees.isFinite, reportedFormatFieldOfViewDegrees > 0,
              reportedFormatFieldOfViewDegrees < 180 else { throw VisionTrialError.invalidReport }
    }
}

public struct VisionContextSample: Codable, Equatable {
    public var elapsedSeconds: Double
    public var screenOrientation: VisionScreenOrientation
    public var motionStatus: VisionMotionStatus
    public var devicePose: VisionDevicePose?
    public var imageWidthPixels: Int
    public var imageHeightPixels: Int
    public var people: Int
    public var trackingQuality: PoseQuality
    public var automaticCount: Int
    public var counterInterruptions: Int
    public var framing: VisionFraming?

    public func validate(frontCamera: Bool, source: VisionInputSource) throws {
        guard elapsedSeconds.isFinite, elapsedSeconds >= 0, (1...16384).contains(imageWidthPixels),
              (1...16384).contains(imageHeightPixels), people >= 0,
              (0...10000).contains(automaticCount), counterInterruptions >= 0,
              framing == nil || people == 1,
              (devicePose != nil) == (motionStatus == .available || motionStatus == .fixture),
              devicePose.map({ $0.source == (source == .fixture ? .fixture : .coreMotion) }) ?? true,
              motionStatus != .fixture || source == .fixture else { throw VisionTrialError.invalidReport }
        try devicePose?.validate(frontCamera: frontCamera)
        try framing?.validate()
    }
}

public struct VisionCaptureContext: Codable, Equatable {
    public var schema = "fox.vision_capture_context.v1"
    public var declaredBodyView: VisionBodyView
    public var bodyViewSource: String
    public var samplingIntervalSeconds = 1.0
    public var droppedSamples: Int
    public var cameraGeometry: VisionCameraGeometry?
    public var samples: [VisionContextSample]
    public init(declaredBodyView: VisionBodyView, droppedSamples: Int = 0, cameraGeometry: VisionCameraGeometry? = nil,
                samples: [VisionContextSample] = []) {
        self.declaredBodyView = declaredBodyView
        bodyViewSource = declaredBodyView == .unknown ? "unlabeled" : "user"
        self.droppedSamples = droppedSamples; self.cameraGeometry = cameraGeometry; self.samples = samples
    }
    public func validate(frontCamera: Bool, source: VisionInputSource) throws {
        guard schema == "fox.vision_capture_context.v1", samplingIntervalSeconds == 1,
              droppedSamples >= 0, samples.count <= 1800,
              bodyViewSource == (declaredBodyView == .unknown ? "unlabeled" : "user") else { throw VisionTrialError.invalidReport }
        var previous = -Double.infinity
        for sample in samples {
            try sample.validate(frontCamera: frontCamera, source: source)
            guard sample.elapsedSeconds > previous else { throw VisionTrialError.invalidReport }
            previous = sample.elapsedSeconds
        }
        try cameraGeometry?.validate()
    }
}

public struct VisionContextRecorder {
    public private(set) var samples: [VisionContextSample] = []
    public private(set) var droppedSamples = 0
    private var lastRecordedSeconds: Double?
    public init() {}

    public mutating func record(elapsedSeconds: Double, screenOrientation: VisionScreenOrientation,
                                motionStatus: VisionMotionStatus, devicePose: VisionDevicePose?, frame: PoseFrame,
                                side: ArmSide, automaticCount: Int, interruptions: Int, exercise: VisionExercise = .curl,
                                configuration: PoseCounterConfiguration = .standard, runtimePolicy: PoseRuntimePolicy? = nil) {
        guard elapsedSeconds.isFinite, elapsedSeconds >= 0,
              lastRecordedSeconds.map({ elapsedSeconds - $0 >= 1 - 0.000001 }) ?? true,
              frame.width.isFinite, frame.height.isFinite,
              (1...16384).contains(frame.width), (1...16384).contains(frame.height) else { return }
        lastRecordedSeconds = elapsedSeconds
        guard samples.count < 1800 else { droppedSamples += 1; return }
        samples.append(VisionContextSample(elapsedSeconds: elapsedSeconds, screenOrientation: screenOrientation,
            motionStatus: motionStatus, devicePose: devicePose, imageWidthPixels: Int(frame.width), imageHeightPixels: Int(frame.height),
            people: frame.people.count, trackingQuality: PoseGeometry.inspect(frame, side: side, exercise: exercise,
                configuration: configuration, runtimePolicy: runtimePolicy).quality,
            automaticCount: automaticCount, counterInterruptions: interruptions, framing: VisionFraming.measure(frame)))
    }
}
