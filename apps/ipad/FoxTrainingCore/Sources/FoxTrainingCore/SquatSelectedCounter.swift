import Foundation

/// Explicit central-person diagnostic. Selection is not a persistent identity claim.
/// Same central-x/short-continuity policy as AssistedCurlSession, with a fixed-side
/// hip anchor and the same explicit confidence floor as the complete leg counter.
public struct SquatSelectedCounter {
    private struct Candidate { let index: Int; let point: PosePoint }
    public let side: ArmSide
    public let jointConfidenceFloor: SquatJointConfidenceFloor
    public var counterJointConfidenceFloor: SquatJointConfidenceFloor { counter.jointConfidenceFloor }
    private let policy = PoseRuntimePolicy.standard
    private var counter: SquatCountOnlyCounter
    private var anchor: PosePoint?
    private var lastTime: Double?
    private var dimensions: [Double]?
    public private(set) var selectedIndex: Int?
    public private(set) var selectedAnchor: PosePoint?
    public private(set) var selectionReason = "waiting"
    public private(set) var selectionBreakReason: String?
    public var events: [SquatCountEvent] { counter.events }
    public var lastAngle: Double? { counter.lastAngle }
    public var lastReason: String { counter.lastReason }
    public init(side: ArmSide, jointConfidenceFloor: SquatJointConfidenceFloor = .baseline) {
        self.side=side;self.jointConfidenceFloor=jointConfidenceFloor
        counter=SquatCountOnlyCounter(side:side,jointConfidenceFloor:jointConfidenceFloor)
    }
    public mutating func interrupt() {
        counter.interrupt();anchor=nil;selectedIndex=nil;selectedAnchor=nil;selectionReason="host_interrupted";selectionBreakReason="host_interrupted"
    }
    private mutating func refuse(_ frame: PoseFrame, _ reason: String) throws {
        interrupt();selectionReason=reason;selectionBreakReason=reason
        try counter.process(PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[]))
    }
    public mutating func process(_ frame: PoseFrame) throws {
        selectionBreakReason=nil
        guard frame.timestamp.isFinite,frame.timestamp>=0,lastTime.map({frame.timestamp>$0}) ?? true,
              frame.width.isFinite,frame.height.isFinite,frame.width>0,frame.height>0,
              max(frame.width,frame.height)<=16384 else {interrupt();throw SquatCounterError.invalidTime}
        if let previous=lastTime,frame.timestamp-previous>0.3+1e-9 {interrupt();selectionBreakReason="source_gap"}
        if let size=dimensions,size != [frame.width,frame.height] {interrupt();selectionBreakReason="geometry_changed"}
        lastTime=frame.timestamp;dimensions=[frame.width,frame.height]
        let required:[PoseJoint] = side == .left ? [.leftHip,.leftKnee,.leftAnkle]:[.rightHip,.rightKnee,.rightAnkle]
        let candidates=frame.people.enumerated().compactMap { index,body -> Candidate? in
            guard required.allSatisfy({body.points[$0].map{$0.isValid && $0.confidence>=jointConfidenceFloor.rawValue} ?? false}),
                  let hip=body.points[required[0]] else {return nil}
            return Candidate(index:index,point:hip)
        }
        let centre=(policy.acquisitionMinX+policy.acquisitionMaxX)*0.5
        func cost(_ c:Candidate,_ prior:PosePoint?)->Double {
            prior.map{hypot(c.point.x-$0.x,c.point.y-$0.y)} ?? abs(c.point.x-centre)
        }
        func ranked(_ prior:PosePoint?)->[Candidate] {
            candidates.filter{prior != nil || (policy.acquisitionMinX...policy.acquisitionMaxX).contains($0.point.x)}.sorted{let a=cost($0,prior),b=cost($1,prior);return a==b ? $0.index<$1.index:a<b}
        }
        var ordered=ranked(anchor)
        guard var chosen=ordered.first else {try refuse(frame,"no_central_leg_chain");return}
        if let prior=anchor,hypot(chosen.point.x-prior.x,chosen.point.y-prior.y)>policy.maximumSubjectJump {
            interrupt();selectionBreakReason="selection_discontinuity";ordered=ranked(nil)
            guard let fresh=ordered.first else {try refuse(frame,"outside_acquisition_after_jump");return}
            chosen=fresh
        }
        let best=cost(chosen,anchor)
        if ordered.dropFirst().contains(where:{cost($0,anchor)-best<policy.ambiguityMargin && frame.people[$0.index].points != frame.people[chosen.index].points}) {
            try refuse(frame,"ambiguous");return
        }
        try counter.process(PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[frame.people[chosen.index]]))
        guard counter.lastReason=="valid" else {
            anchor=nil;selectedIndex=nil;selectedAnchor=nil;selectionReason="counter_"+counter.lastReason;selectionBreakReason=selectionReason;return
        }
        anchor=chosen.point;selectedIndex=chosen.index;selectedAnchor=chosen.point;selectionReason="observed"
    }
}
