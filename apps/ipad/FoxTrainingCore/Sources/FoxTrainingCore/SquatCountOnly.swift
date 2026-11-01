import Foundation

public enum SquatCounterError: Error { case invalidTime }
public struct SquatCountEvent: Codable, Equatable {
    public let startedAtSeconds: Double
    public let lowEndpointCandidateSeconds: Double
    public let completedAtSeconds: Double
}

/// Portable frozen squat branch of the geometric CoverageCounter baseline.
/// No experiment-library dependency. Angles are counting gates, not form scores
/// or measured anatomical phases. New modes remain disabled by the host by default.
public struct SquatCountOnlyCounter {
    public let side: ArmSide
    public let capability = "count_only_experimental"
    public private(set) var events: [SquatCountEvent] = []
    public private(set) var lastAngle: Double?
    public private(set) var lastReason = "waiting"
    public private(set) var resets: [String:Int] = [:]
    private enum State { case waiting, ready, low }
    private var state = State.waiting
    private var lastTime: Double?
    private var anchor: PosePoint?
    private var dwell: Double?
    private var dwellKind: String?
    private var cycleStart: Double?
    private var lowTime: Double?

    public init(side: ArmSide) { self.side=side }
    /// A host discontinuity discards only unfinished evidence. It does not emit
    /// a training pause, invent a missing frame, or remove completed events.
    public mutating func interrupt() { lastAngle=nil; reset("host_interrupted") }
    private mutating func reset(_ reason: String) {
        state = .waiting; dwell = nil; dwellKind = nil; cycleStart = nil; lowTime = nil; anchor = nil
        resets[reason, default:0] += 1
        lastReason = reason
    }
    public mutating func process(_ frame: PoseFrame) throws {
        guard frame.timestamp.isFinite, frame.timestamp >= 0,
              lastTime.map({ frame.timestamp > $0 }) ?? true else { throw SquatCounterError.invalidTime }
        let time = frame.timestamp
        if let previous = lastTime, time - previous > 0.30 + 1e-9 { reset("time_gap") }
        lastTime = time; lastAngle = nil
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
              max(frame.width, frame.height) <= 16384 else { reset("invalid_frame"); return }
        guard frame.people.count == 1 else { reset(frame.people.isEmpty ? "no_person" : "multiple_people"); return }
        let left = side == .left
        let hip: PoseJoint = left ? .leftHip : .rightHip
        let required: [PoseJoint] = [hip, left ? .leftKnee : .rightKnee, left ? .leftAnkle : .rightAnkle]
        let points = frame.people[0].points
        guard required.allSatisfy({ points[$0].map { $0.isValid && $0.confidence >= 0.5 } ?? false }) else {
            reset("missing_required_joint"); return
        }
        let a = points[required[0]]!, b = points[required[1]]!, c = points[required[2]]!
        let u = ((a.x-b.x)*frame.width, (a.y-b.y)*frame.height)
        let v = ((c.x-b.x)*frame.width, (c.y-b.y)*frame.height)
        let l1 = hypot(u.0,u.1), l2 = hypot(v.0,v.1)
        guard min(l1,l2) >= 0.025 * min(frame.width,frame.height) else { reset("degenerate_segment"); return }
        if a.y <= c.y { reset("unsupported_body_geometry"); return }
        // Anchor is action-specific: a lower-body view must not require an invisible shoulder.
        if let old = anchor, hypot(a.x-old.x,a.y-old.y) > 0.35 { reset("subject_jump"); return }
        anchor = a
        let angle = acos(max(-1,min(1,(u.0*v.0+u.1*v.1)/(l1*l2)))) * 180 / .pi
        lastAngle = angle; lastReason = "valid"
        if let start = cycleStart, time-start > 20 { reset("cycle_timeout"); return }
        let high = angle >= 155, low = angle <= 110
        let kind = high ? "high" : (low ? "low" : "middle")
        if kind != dwellKind { dwellKind = kind; dwell = time }
        let sustained = time - (dwell ?? time) >= 0.10 - 1e-9
        switch state {
        case .waiting:
            if high && sustained { state = .ready }
        case .ready:
            if !high && cycleStart == nil { cycleStart = time }
            if low && sustained && cycleStart != nil { state = .low; lowTime = dwell }
            // A partial descent returning high is not a completed repetition.
            if high && sustained { cycleStart = nil }
        case .low:
            if high && sustained {
                if let start = cycleStart, let bottom = lowTime, time-start >= 0.5 {
                    events.append(SquatCountEvent(startedAtSeconds:start, lowEndpointCandidateSeconds:bottom, completedAtSeconds:time))
                }
                state = .ready; cycleStart = nil; lowTime = nil
            }
        }
    }
}
