import Foundation

public struct VisionWorkflowEvent: Codable, Equatable {
    public let id: String
    public let completedAtSourcePTSSeconds: Double
    public let startedAtSourcePTSSeconds: Double?
    public let peakGateAtSourcePTSSeconds: Double?
    public let returnGateAtSourcePTSSeconds: Double?
}
public struct VisionWorkflowTrace: Codable {
    public let sourcePTSSeconds: Double
    public let admitted: Bool
    public let formal: Bool
    public let selectedIndex: Int?
    public let reason: String
    public let automaticCount: Int
    public let reset: Bool
    public let resetReason: String?
    public init(sourcePTSSeconds:Double,admitted:Bool,formal:Bool,selectedIndex:Int?,reason:String,automaticCount:Int,reset:Bool,resetReason:String?) {
        self.sourcePTSSeconds=sourcePTSSeconds;self.admitted=admitted;self.formal=formal;self.selectedIndex=selectedIndex
        self.reason=reason;self.automaticCount=automaticCount;self.reset=reset;self.resetReason=resetReason
    }
}
public struct VisionWorkflowReplayResult: Codable {
    public let binding: VisionActionBinding
    public let sourceOriginSeconds: Double
    public let formalStartSeconds: Double
    public let side: ArmSide
    public let events: [VisionWorkflowEvent]
    public let trace: [VisionWorkflowTrace]
    public let legacyRepetitions: [CurlRepetition]?
    public let resetCounts: [String:Int]
    public var execution = "portable_core_replay_not_actual_app"
    public var acceptance = "not_assessed"
    public var selectionMeaning = "central_observation_not_verified_person_identity"
    public var timebase = "original_source_pts_seconds_double_not_complete_cmtime"
}

/// Thin orchestration over the existing implementations. No motion thresholds are owned here.
/// Formal/reference start is fixed even when the original arm preparation gate becomes ready later.
public enum VisionWorkflowReplay {
    public static func run(action: String, side: ArmSide, frames: [PoseFrame]) throws -> VisionWorkflowReplayResult {
        let binding=try VisionActionBinding.load(action), registry=try VisionActionRegistry.load()
        guard let first=frames.first, let last=frames.last, first.timestamp>=0,
              last.timestamp>=first.timestamp+registry.formalOffsetSeconds,
              zip(frames,frames.dropFirst()).allSatisfy({$0.timestamp.isFinite && $0.timestamp<$1.timestamp})
        else {throw TrainingError.invalidRecord}
        let formal=first.timestamp+registry.formalOffsetSeconds
        var cadence=PoseFrameCadenceGate(), trace:[VisionWorkflowTrace]=[]
        var squat=SquatSelectedCounter(side:side)
        var selector=PoseSubjectSelector(), gate=PoseStartGate(lossTolerance:PoseRuntimePolicy.standard.countdownLossTolerance)
        var tracker=CurlTracker(side:side,exercise:.curl,configuration:.standard,runtimePolicy:.standard)
        var counting=false, trackerOrigin:Double?
        gate.arm()
        for frame in frames {
            let admitted=cadence.accepts(frame.timestamp)
            var reason="cadence_not_admitted", index:Int?, resetReason:String?
            if admitted {
                if action=="squat" {
                    if frame.timestamp<formal {reason="preview_only"}
                    else {
                        try squat.process(frame);reason=squat.lastReason=="valid" ? "observed":squat.selectionReason
                        index=squat.selectedIndex;resetReason=squat.selectionBreakReason
                    }
                } else {
                    let previous=selector.selection.state
                    var selection=selector.process(frame,side:side)
                    if !counting && selection.state == .lost {
                        selector.reset();gate.invalidate();selection=selector.process(frame,side:side)
                    }
                    if !counting && selection.state == .ambiguous {gate.invalidate()}
                    let selected=selection.selectedFrame(from:frame)
                    if !counting {
                        let ready=PoseSubjectSelector.isReady(selected,side:side,confidence:PoseRuntimePolicy.standard.subjectConfidence)
                        if gate.process(timestamp:frame.timestamp,poseReady:ready) == .ready {
                            counting=true;trackerOrigin=frame.timestamp
                        }
                    }
                    if counting {
                        if selection.state == .lost && previous != .lost {tracker.interrupt();resetReason="subject_lost"}
                        _=tracker.process(selected,originalPeopleCount:frame.people.count,selection:selection)
                        reason=tracker.snapshot.failureReason?.rawValue ?? (tracker.snapshot.quality == .valid ? "observed":tracker.snapshot.quality.rawValue)
                    } else {reason="preparing_\(selection.state.rawValue)"}
                    index=selection.index
                }
            }
            trace.append(.init(sourcePTSSeconds:frame.timestamp,admitted:admitted,formal:frame.timestamp>=formal,
                selectedIndex:index,reason:reason,automaticCount:action=="squat" ? squat.events.count:tracker.repetitions.count,
                reset:resetReason != nil,resetReason:resetReason))
        }
        let events:[VisionWorkflowEvent]
        if action=="squat" {
            events=squat.events.enumerated().map {i,e in .init(id:String(i+1),completedAtSourcePTSSeconds:e.completedAtSeconds,
                startedAtSourcePTSSeconds:e.startedAtSeconds,peakGateAtSourcePTSSeconds:e.lowEndpointCandidateSeconds,returnGateAtSourcePTSSeconds:nil)}
        } else {
            let origin=trackerOrigin ?? first.timestamp
            events=tracker.repetitions.enumerated().map {i,e in .init(id:String(i+1),completedAtSourcePTSSeconds:origin+e.completedAtSeconds,
                startedAtSourcePTSSeconds:e.startedAtSeconds.map{origin+$0},peakGateAtSourcePTSSeconds:e.peakAtSeconds.map{origin+$0},
                returnGateAtSourcePTSSeconds:e.loweredAtSeconds.map{origin+$0})}
        }
        return .init(binding:binding,sourceOriginSeconds:first.timestamp,formalStartSeconds:formal,side:side,events:events,
            trace:trace,legacyRepetitions:action=="curl" ? tracker.repetitions:nil,resetCounts:action=="curl" ? tracker.diagnostics.resetCounts:[:])
    }
}
