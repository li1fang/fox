import Foundation

public enum AssistedPoseSource: String, Codable { case cachedPose, cameraPose }
public struct AssistedCountEvent: Codable, Equatable {
    public let completedAtSeconds: Double
    public let segmentID: Int
}
public struct AssistedObservationSegment: Codable, Equatable {
    public let id: Int
    public let startedAtSeconds: Double
    public var endedAtSeconds: Double?
    public var endReason: String?
}
/// Separate from phase-bearing WorkoutVisualEvidence. No guessed phase or manual-as-visual promotion.
public struct AssistedCurlEvidence: Codable, Equatable {
    public var schema = "fox.assisted_curl_evidence.v1"
    public var algorithm = "central-continuous-curl-v1"
    public var phaseStatus = "not_provided"
    public let source: AssistedPoseSource
    public let side: ArmSide
    public let inputOriginSeconds: Double
    public let formalStartSeconds: Double
    public let lastInputSeconds: Double?
    public let events: [AssistedCountEvent]
    public let segments: [AssistedObservationSegment]
    public var observedCount: Int { events.count }
    public func validate() throws {
        guard schema == "fox.assisted_curl_evidence.v1", algorithm == "central-continuous-curl-v1",
              phaseStatus == "not_provided", inputOriginSeconds.isFinite, inputOriginSeconds >= 0,
              formalStartSeconds.isFinite, formalStartSeconds >= inputOriginSeconds,
              lastInputSeconds.map({ $0.isFinite && $0 >= inputOriginSeconds }) ?? true else { throw VisionTrialError.invalidReport }
        let last = (lastInputSeconds ?? inputOriginSeconds)-inputOriginSeconds
        var previousEnd = formalStartSeconds-inputOriginSeconds
        for (i,s) in segments.enumerated() {
            guard s.id == i, s.startedAtSeconds.isFinite, s.startedAtSeconds >= previousEnd,
                  s.startedAtSeconds <= last,
                  (s.endedAtSeconds == nil) == (s.endReason == nil) else { throw VisionTrialError.invalidReport }
            if let end=s.endedAtSeconds {
                guard end.isFinite, end >= s.startedAtSeconds, end <= last, !(s.endReason?.isEmpty ?? true) else { throw VisionTrialError.invalidReport }
                previousEnd=end
            } else {
                guard i == segments.count-1 else { throw VisionTrialError.invalidReport }
                previousEnd=s.startedAtSeconds
            }
        }
        var previous = -Double.infinity
        for e in events {
            guard e.completedAtSeconds.isFinite, e.completedAtSeconds > previous,
                  segments.indices.contains(e.segmentID) else { throw VisionTrialError.invalidReport }
            let s=segments[e.segmentID]
            guard e.completedAtSeconds >= s.startedAtSeconds,
                  e.completedAtSeconds <= (s.endedAtSeconds ?? last) else { throw VisionTrialError.invalidReport }
            previous=e.completedAtSeconds
        }
    }
}
/// Host persistence envelope; confirmation is independent, even when numerically equal.
public struct AssistedCurlRecord: Codable, Equatable {
    public var schema = "fox.assisted_curl_record.v1"
    public let evidence: AssistedCurlEvidence
    public let confirmedCount: Int?
    public init(evidence: AssistedCurlEvidence, confirmedCount: Int? = nil) throws {
        self.evidence=evidence; self.confirmedCount=confirmedCount; try validate()
    }
    public func validate() throws {
        guard schema == "fox.assisted_curl_record.v1", confirmedCount.map({$0 >= 0}) ?? true else { throw VisionTrialError.invalidReport }
        try evidence.validate()
    }
    public static func decode(_ data: Data) throws -> AssistedCurlRecord {
        let value=try JSONDecoder().decode(Self.self,from:data); try value.validate(); return value
    }
}

/// Opt-in host session. Publishes observations only; it cannot pause/end/reprepare a workout.
/// Centre selection is a product assumption, not persistent person identity recognition.
public struct AssistedCurlSession {
    private struct Candidate { let index: Int; let x: Double; let y: Double }
    private let side: ArmSide
    private let source: AssistedPoseSource
    private let origin: Double
    private let formalStart: Double
    private let policy = PoseRuntimePolicy.standard
    private var counter: FrontalCurlCounter
    private var mapper: SameArmChannelMapper
    private var anchor: Candidate?
    private var dimensions: [Double]?
    private var lastTime: Double?
    private var started = false
    private var closed = false
    private var events: [AssistedCountEvent] = []
    private var segments: [AssistedObservationSegment] = []
    private var activeSegment: Int?
    public private(set) var selectedIndex: Int?
    public private(set) var reason = "waiting_for_observation"
    public var counterState: String { counter.state }
    public var signal: Double? { counter.signal }
    public var modelChannel: ArmSide? { mapper.reportedChannel }
    public var formalStarted: Bool { started }
    public var evidence: AssistedCurlEvidence {
        AssistedCurlEvidence(source:source,side:side,inputOriginSeconds:origin,formalStartSeconds:formalStart,
                             lastInputSeconds:lastTime,events:events,segments:segments)
    }
    public init(side: ArmSide, originSeconds: Double, formalStartSeconds: Double? = nil,
                source: AssistedPoseSource = .cachedPose) throws {
        let start=formalStartSeconds ?? originSeconds
        guard originSeconds.isFinite, originSeconds >= 0, start.isFinite, start >= originSeconds else { throw VisionTrialError.invalidReport }
        self.side=side;self.source=source;origin=originSeconds;formalStart=start
        mapper=SameArmChannelMapper(side:side)
        counter=FrontalCurlCounter(side:side,originSeconds:originSeconds,variant:.high040,
            confidenceProfile:.maintaining225,risingLowRearm:true,countPolicy:.observedReturn,timingPolicy:.variablePTS)
    }
    private mutating func breakObservation(at time: Double, reason: String) {
        if let id=activeSegment {
            segments[id].endedAtSeconds=time-origin;segments[id].endReason=reason;activeSegment=nil
        }
        counter.interrupt();mapper=SameArmChannelMapper(side:side);anchor=nil;selectedIndex=nil
        self.reason=reason
    }
    /// Called only by the owning host for a real input lifecycle discontinuity. No frontend command is emitted.
    public mutating func inputInterrupted(at time: Double) throws {
        guard !closed, time.isFinite, time >= (lastTime ?? origin) else { throw VisionTrialError.invalidReport }
        lastTime=time;breakObservation(at:time,reason:"input_interrupted")
    }
    public mutating func close() {
        if !closed { breakObservation(at:lastTime ?? origin,reason:"host_closed");closed=true }
    }
    public mutating func process(_ frame: PoseFrame) throws {
        guard !closed, frame.timestamp.isFinite, frame.timestamp >= origin,
              lastTime.map({ frame.timestamp > $0 }) ?? true,
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            if !closed { breakObservation(at:lastTime ?? origin,reason:"invalid_input") }
            throw VisionTrialError.invalidReport
        }
        if let previous=lastTime, frame.timestamp-previous > 0.3+1e-9 {
            breakObservation(at:frame.timestamp,reason:"source_gap")
        }
        if let size=dimensions, size != [frame.width,frame.height] {
            breakObservation(at:frame.timestamp,reason:"geometry_changed")
        }
        lastTime=frame.timestamp;dimensions=[frame.width,frame.height]
        if !started, frame.timestamp >= formalStart {
            _=counter.beginFormalCounting();started=true
        }
        let candidates=frame.people.enumerated().compactMap { index,body -> Candidate? in
            let points=[PoseJoint.leftShoulder,.rightShoulder].compactMap { body.points[$0] }
                .filter { $0.isValid && $0.confidence >= 0.25 }
            guard !points.isEmpty else { return nil }
            let x=points.map(\.x).reduce(0,+)/Double(points.count)
            let y=points.map(\.y).reduce(0,+)/Double(points.count)
            guard (policy.acquisitionMinX...policy.acquisitionMaxX).contains(x) else { return nil }
            return Candidate(index:index,x:x,y:y)
        }
        let centre=(policy.acquisitionMinX+policy.acquisitionMaxX)*0.5
        // Use existing points only. No embeddings, external tracker or per-person history.
        func cost(_ c: Candidate, _ prior: Candidate?) -> Double {
            prior.map { hypot(c.x-$0.x,c.y-$0.y) } ?? abs(c.x-centre)
        }
        func ranked(_ prior: Candidate?) -> [Candidate] {
            candidates.sorted { a,b in
                let ca=cost(a,prior), cb=cost(b,prior)
                return ca == cb ? a.index < b.index : ca < cb
            }
        }
        var ordered=ranked(anchor)
        guard var chosen=ordered.first else {
            breakObservation(at:frame.timestamp,reason:"no_central_observation");return
        }
        if let prior=anchor, hypot(chosen.x-prior.x,chosen.y-prior.y) > policy.maximumSubjectJump {
            breakObservation(at:frame.timestamp,reason:"selection_discontinuity")
            ordered=ranked(nil);chosen=ordered[0]
        }
        // Exact duplicate observations are interchangeable. Distinct equally plausible
        // bodies must not donate alternate halves of one cycle; next frame still runs.
        let bestCost=cost(chosen,anchor)
        if ordered.dropFirst().contains(where: {
            cost($0,anchor)-bestCost < policy.ambiguityMargin &&
            frame.people[$0.index].points != frame.people[chosen.index].points
        }) {
            breakObservation(at:frame.timestamp,reason:"central_observation_ambiguous");return
        }
        let single=PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[frame.people[chosen.index]])
        let mapped=mapper.normalize(single)
        guard FrontalCurlSignal.value(mapped,side:side,gate:anchor == nil ? .acquisition:.maintaining) != nil else {
            breakObservation(at:frame.timestamp,reason:"arm_unobservable");return
        }
        let before=counter.events.count
        try counter.process(mapped)
        guard counter.lastReason == "valid" else {
            breakObservation(at:frame.timestamp,reason:counter.lastReason);return
        }
        anchor=chosen;selectedIndex=chosen.index;mapper.markBound();reason="observed"
        if started {
            if activeSegment == nil {
                let id=segments.count;segments.append(AssistedObservationSegment(id:id,startedAtSeconds:frame.timestamp-origin));activeSegment=id
            }
            if counter.events.count > before, let id=activeSegment {
                events.append(AssistedCountEvent(completedAtSeconds:counter.events.last!.completedAtSeconds,segmentID:id))
            }
        }
    }
}
