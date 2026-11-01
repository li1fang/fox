import Foundation

public enum FrontalConfidenceProfile: String {
    case uniform275 = "frontal-uniform275-v1"
    case maintaining225 = "frontal-bound225-v1"
}
public enum FrontalConfidenceGate {
    case acquisition, maintaining
    public var minimum: Double { self == .acquisition ? 0.275 : 0.225 }
}

/// Fixed offline frontal-view signal. It is a 2D proxy, not a measured joint angle.
public enum FrontalCurlSignal {
    public static func value(_ frame: PoseFrame, side: ArmSide, gate: FrontalConfidenceGate = .acquisition) -> Double? {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
              frame.people.count == 1 else { return nil }
        let p = frame.people[0].points
        let points = side.joints.compactMap { p[$0] }
        guard points.count == 3, points.allSatisfy({ $0.isValid && $0.confidence >= gate.minimum }) else { return nil }
        let shoulder=points[0], elbow=points[1], wrist=points[2]
        let upper=hypot((shoulder.x-elbow.x)*frame.width,(shoulder.y-elbow.y)*frame.height)
        guard upper >= frame.height*0.025 else { return nil }
        let signal=(wrist.y-elbow.y)*frame.height/upper
        return signal.isFinite ? signal : nil
    }
}

public struct FrontalCurlEvent: Codable {
    /// Seconds relative to the first input frame, not an anatomical phase measurement.
    public let completedAtSeconds: Double
}

public enum FrontalCurlVariant: String {
    case original = "frontal-original-v1"
    case high040 = "frontal-high040-v1"
    public var high: Double { self == .high040 ? 0.40 : 0.65 }
}

public enum FrontalCountPolicy: String {
    case original = "high-dwell-v1"
    case observedReturn = "observed-return-v1"
}

public enum FrontalTimingPolicy: String, Codable { case strictCache, variablePTS }

/// Offline count-only candidate. Never bridges a missing or discontinuous observation.
public struct FrontalCurlCounter {
    public let side: ArmSide
    public let originSeconds: Double
    public let variant: FrontalCurlVariant
    public let confidenceProfile: FrontalConfidenceProfile
    public let risingLowRearm: Bool
    public let countPolicy: FrontalCountPolicy
    public let expectedFrameInterval: Double?
    public let timingPolicy: FrontalTimingPolicy
    public private(set) var events: [FrontalCurlEvent] = []
    public private(set) var lastReason = "waiting"
    public private(set) var state = "waiting_low"
    public private(set) var signal: Double?
    private var lastTime: Double?
    private var lastRaw: Double?
    private var smooth: Double?
    private var lowSince: Double?
    private var highSince: Double?
    private var highFrames = 0
    private var start: Double?
    private var fallStart: Double?

    public init(side: ArmSide, originSeconds: Double, variant: FrontalCurlVariant = .original,
                confidenceProfile: FrontalConfidenceProfile = .uniform275, risingLowRearm: Bool = false,
                countPolicy: FrontalCountPolicy = .original, expectedFrameInterval: Double? = nil, timingPolicy: FrontalTimingPolicy = .strictCache) {
        self.side=side; self.originSeconds=originSeconds; self.variant=variant; self.confidenceProfile=confidenceProfile; self.risingLowRearm=risingLowRearm; self.countPolicy=countPolicy; self.expectedFrameInterval=expectedFrameInterval; self.timingPolicy=timingPolicy
    }
    public mutating func interrupt() {
        state="waiting_low"; signal=nil; lastRaw=nil; smooth=nil; lowSince=nil; highSince=nil; highFrames=0; start=nil; fallStart=nil
    }
    /// Separate pre-start observations. A partial movement cannot cross the start.
    public mutating func beginFormalCounting() -> [FrontalCurlEvent] {
        let preparation = events
        events.removeAll()
        if state != "ready_low" { interrupt() }
        return preparation
    }
    public mutating func process(_ frame: PoseFrame) throws {
        guard frame.timestamp.isFinite, frame.timestamp >= originSeconds,
              lastTime.map({ frame.timestamp > $0 }) ?? true else { throw VisionTrialError.invalidReport }
        let previousTime=lastTime; lastTime=frame.timestamp
        if let previousTime {
            let delta=frame.timestamp-previousTime
            if delta > 0.3+1e-9 || (timingPolicy == .strictCache && countPolicy == .observedReturn && expectedFrameInterval.map({ !$0.isFinite || $0 <= 0 || abs(delta-$0) > 1e-6 }) != false) { interrupt() }
        }
        let gate: FrontalConfidenceGate = confidenceProfile == .maintaining225 ? .maintaining : .acquisition
        guard let raw=FrontalCurlSignal.value(frame,side:side,gate:gate) else {
            interrupt(); lastReason="invalid_signal"; return
        }
        if let prior=lastRaw, abs(raw-prior)>1.0 {
            interrupt(); lastReason="signal_jump"; return
        }
        let dt=previousTime.map { frame.timestamp-$0 } ?? 0
        let value=smooth.map { $0+(1-exp(-dt/0.08))*(raw-$0) } ?? raw
        lastRaw=raw; smooth=value; signal=value; lastReason="valid"
        if let start, frame.timestamp-start > 20 { interrupt(); lastReason="cycle_timeout"; return }
        switch state {
        case "waiting_low":
            if value <= -0.65 {
                if lowSince == nil { lowSince=frame.timestamp }
                if frame.timestamp-lowSince! >= 0.18-1e-9 { state="ready_low"; lowSince=nil }
            } else { lowSince=nil }
        case "ready_low":
            if value > -0.65 { start=frame.timestamp; state="rising" }
        case "rising":
            if value <= -0.65 {
                state=risingLowRearm ? "ready_low" : "waiting_low"; start=nil; highSince=nil; highFrames=0; fallStart=nil; lowSince=risingLowRearm ? nil : frame.timestamp
            } else { lowSince=nil }
            if state == "rising" && value >= variant.high {
                if highSince == nil { highSince=frame.timestamp }
                highFrames += 1
                let witnessed = countPolicy == .observedReturn ? highFrames >= 2 : frame.timestamp-highSince! >= 0.18-1e-9
                if witnessed, highSince!-start! >= 0.10-1e-9 {
                    state="ready_high"; highSince=nil; highFrames=0
                }
            } else { highSince=nil; highFrames=0 }
        case "ready_high":
            if value < variant.high, fallStart == nil { fallStart=frame.timestamp }
            if value >= variant.high { fallStart=nil; lowSince=nil }
            else if value <= -0.65 {
                if lowSince == nil { lowSince=frame.timestamp }
                if frame.timestamp-lowSince! >= 0.10-1e-9, let fallStart, lowSince!-fallStart >= 0.10-1e-9 {
                    events.append(FrontalCurlEvent(completedAtSeconds:frame.timestamp-originSeconds))
                    state="waiting_low"; start=nil; self.fallStart=nil; lowSince=nil
                }
            } else { lowSince=nil }
        default: interrupt(); lastReason="invalid_state"
        }
    }
}
