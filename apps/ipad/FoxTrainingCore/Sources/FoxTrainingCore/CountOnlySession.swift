import Foundation

public enum CountOnlyAction: String, Codable {
    case curl, squat
    public var algorithm: String { self == .curl ? "central-continuous-curl-v1" : "squat-selected-count-only-v1" }
    public var label: String { self == .curl ? "近正面弯举辅助" : "侧面深蹲辅助" }
}

/// Count gates are not anatomical phase endpoints. No period/rhythm is inferred here.
public struct CountOnlyEvidence: Codable, Equatable {
    public var schema = "fox.count_only_evidence.v1"
    public let action: CountOnlyAction
    public let algorithm: String
    public var phaseStatus = "not_provided"
    public let source: AssistedPoseSource
    public let side: ArmSide
    public let inputOriginSeconds: Double
    public let formalStartSeconds: Double
    public let lastInputSeconds: Double?
    public let events: [AssistedCountEvent]
    public let segments: [AssistedObservationSegment]
    public var observedCount: Int { events.count }
    public init(_ curl: AssistedCurlEvidence) {
        action = .curl; algorithm=curl.algorithm; source=curl.source; side=curl.side
        inputOriginSeconds=curl.inputOriginSeconds;formalStartSeconds=curl.formalStartSeconds
        lastInputSeconds=curl.lastInputSeconds;events=curl.events;segments=curl.segments
    }
    init(source: AssistedPoseSource, side: ArmSide, origin: Double, formalStart: Double, last: Double?,
         events: [AssistedCountEvent], segments: [AssistedObservationSegment]) {
        action = .squat;algorithm=action.algorithm;self.source=source;self.side=side
        inputOriginSeconds=origin;formalStartSeconds=formalStart;lastInputSeconds=last;self.events=events;self.segments=segments
    }
    public var curlEvidence: AssistedCurlEvidence? {
        guard action == .curl else { return nil }
        return AssistedCurlEvidence(source:source,side:side,inputOriginSeconds:inputOriginSeconds,
            formalStartSeconds:formalStartSeconds,lastInputSeconds:lastInputSeconds,events:events,segments:segments)
    }
    public func validate() throws {
        guard schema == "fox.count_only_evidence.v1", algorithm == action.algorithm,
              phaseStatus == "not_provided" else { throw TrainingError.corruptArchive }
        // The shared PTS/unique-segment contract has no action thresholds or phase inference.
        try AssistedCurlEvidence(source:source,side:side,inputOriginSeconds:inputOriginSeconds,
            formalStartSeconds:formalStartSeconds,lastInputSeconds:lastInputSeconds,events:events,segments:segments).validate()
    }
}

/// Two explicit count-only routes. Squat retains the frozen single-person, fixed-side 0.5 gate.
public struct CountOnlySession {
    public let action: CountOnlyAction
    private let side: ArmSide
    private let source: AssistedPoseSource
    private let origin: Double
    private let formalStart: Double
    private var curl: AssistedCurlSession?
    private var squat: SquatSelectedCounter?
    private var lastTime: Double?
    private var events: [AssistedCountEvent] = []
    private var segments: [AssistedObservationSegment] = []
    private var activeSegment: Int?
    public private(set) var reason = "waiting_for_observation"
    public var evidence: CountOnlyEvidence {
        if let curl { return CountOnlyEvidence(curl.evidence) }
        return CountOnlyEvidence(source:source,side:side,origin:origin,formalStart:formalStart,last:lastTime,events:events,segments:segments)
    }
    public init(action: CountOnlyAction, side: ArmSide, originSeconds: Double, source: AssistedPoseSource, formalStartSeconds: Double? = nil) throws {
        let formal=formalStartSeconds ?? originSeconds
        guard originSeconds.isFinite, originSeconds >= 0, formal.isFinite, formal >= originSeconds else { throw TrainingError.invalidRecord }
        self.action=action;self.side=side;origin=originSeconds;self.source=source;formalStart=formal
        if action == .curl { curl=try AssistedCurlSession(side:side,originSeconds:originSeconds,formalStartSeconds:formal,source:source) }
        else { squat=SquatSelectedCounter(side:side) }
    }
    public mutating func inputInterrupted() {
        if let time=curl?.evidence.lastInputSeconds { try? curl?.inputInterrupted(at:time) }
        if let id=activeSegment { segments[id].endedAtSeconds=(lastTime ?? origin)-origin;segments[id].endReason="input_interrupted" }
        activeSegment=nil;squat?.interrupt();reason="observation_interrupted"
    }
    public mutating func process(_ frame: PoseFrame) throws {
        if curl != nil { try curl!.process(frame);reason=curl!.reason;return }
        guard frame.timestamp.isFinite, frame.timestamp >= origin,
              lastTime.map({frame.timestamp > $0}) ?? true else {
            inputInterrupted();throw TrainingError.invalidRecord
        }
        let previous=lastTime
        lastTime=frame.timestamp
        if frame.timestamp<formalStart {reason="preview_only";return}
        let before=squat!.events.count
        try squat!.process(frame)
        if let interruption=squat!.selectionBreakReason, let id=activeSegment {
            segments[id].endedAtSeconds=(previous ?? frame.timestamp)-origin
            segments[id].endReason=interruption;activeSegment=nil
        }
        guard squat!.lastReason == "valid" else {reason=squat!.selectionReason;return}
        reason="observed"
        if activeSegment == nil {
            let id=segments.count;segments.append(AssistedObservationSegment(id:id,startedAtSeconds:frame.timestamp-origin));activeSegment=id
        }
        if squat!.events.count > before, let id=activeSegment {
            events.append(AssistedCountEvent(completedAtSeconds:squat!.events.last!.completedAtSeconds-origin,segmentID:id))
        }
    }
}
