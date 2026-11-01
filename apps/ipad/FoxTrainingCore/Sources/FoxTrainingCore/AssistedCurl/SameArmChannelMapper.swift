import Foundation

/// Experimental local correspondence only; model channels are not anatomical identity.
/// Switch requires two independently distinguishable shoulder/elbow chains to cross-match.
struct SameArmChannelMapper {
    private struct Chain { let x:Double; let y:Double; let length:Double }
    private var anchors: [ArmSide:Chain] = [:]
    private(set) var reason = "mapping_unavailable"
    private(set) var sourcePersonIndex: Int?
    private var hasBound = false
    private var invalidated = false
    var reportedChannel: ArmSide? { invalidated ? nil : selectedChannel }
    mutating func markBound() { hasBound = true }
    private(set) var selectedChannel: ArmSide
    private let logicalSide: ArmSide
    private var lastTime: Double?
    private var dimensions: [Double]?
    init(side:ArmSide) { logicalSide=side; selectedChannel=side }
    private func opposite(_ side:ArmSide)->ArmSide { side == .left ? .right : .left }
    private func chain(_ frame:PoseFrame,_ side:ArmSide)->Chain? {
        guard frame.people.count==1,frame.width.isFinite,frame.height.isFinite,frame.width>0,frame.height>0,
              let a=frame.people[0].points[side.joints[0]],let b=frame.people[0].points[side.joints[1]],
              a.isValid,b.isValid,a.confidence>=0.25,b.confidence>=0.25 else {return nil}
        let d=hypot(frame.width,frame.height),length=hypot((a.x-b.x)*frame.width,(a.y-b.y)*frame.height)/d
        guard length >= 0.025*min(frame.width,frame.height)/d else {return nil}
        return Chain(x:(a.x+b.x)*0.5*frame.width/d,y:(a.y+b.y)*0.5*frame.height/d,length:length)
    }
    private func distance(_ a:Chain,_ b:Chain)->Double { hypot(a.x-b.x,a.y-b.y) }
    private func cost(_ a:Chain,_ b:Chain)->Double { distance(a,b) + 0.03 * abs(log(a.length/b.length)) }
    private func compatible(_ a:Chain,_ b:Chain)->Bool {
        hypot(a.x-b.x,a.y-b.y)<=0.18 && (0.55...1.8).contains(b.length/a.length)
    }
    mutating func normalize(_ frame:PoseFrame)->PoseFrame {
        reason="mapping_unavailable";sourcePersonIndex=nil
        if invalidated {reason="unknown_invalidated";return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])}
        guard frame.timestamp.isFinite,frame.timestamp >= 0,frame.width.isFinite,frame.height.isFinite,frame.width>0,frame.height>0,
              lastTime.map({frame.timestamp > $0 && frame.timestamp-$0 <= 0.3+1e-9}) ?? true,
              dimensions.map({$0 == [frame.width,frame.height]}) ?? true else {
            invalidated=true;reason="unknown_time_or_geometry_gap"
            return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])
        }
        if frame.people.count > 1 {
            guard hasBound,let target=anchors[logicalSide] else {
                lastTime=frame.timestamp;dimensions=[frame.width,frame.height];reason="unknown_initial_multiple"
                return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])
            }
            var possibilities:[(Int,PoseFrame,SameArmChannelMapper)]=[]
            for (index,person) in frame.people.enumerated() {
                var candidate=self
                let single=PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[person])
                let mapped=candidate.normalize(single)
                if !candidate.reason.hasPrefix("unknown"),let c=candidate.chain(mapped,logicalSide),compatible(target,c) {
                    possibilities.append((index,mapped,candidate))
                }
            }
            guard possibilities.count == 1, let only=possibilities.first else {
                lastTime=frame.timestamp;dimensions=[frame.width,frame.height];reason="unknown_multiple_or_no_match"
                return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])
            }
            self=only.2;sourcePersonIndex=only.0;reason="unique_person_"+reason
            return only.1
        }
        lastTime=frame.timestamp;dimensions=[frame.width,frame.height]
        guard frame.people.count==1 else {reason="unknown_person_count";return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])}
        sourcePersonIndex=0
        let other=opposite(selectedChannel),current=chain(frame,selectedChannel),alternate=chain(frame,other)
        if current == nil || alternate == nil {
            // A single channel cannot prove a swap. It may only continue the
            // anchored target if geometry excludes the previously observed other arm.
            guard let current else {reason="unknown_target_missing";return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])}
            if let target=anchors[logicalSide] {
                guard compatible(target,current) else {reason="unknown_target_missing";return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])}
                if let otherAnchor=anchors[opposite(logicalSide)], compatible(otherAnchor,current), cost(target,current)+0.015 >= cost(otherAnchor,current) {
                    reason="unknown_ambiguous_single_chain";return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])
                }
                reason="single_channel_anchor_compatible"
            } else {reason="initial_selected_channel"}
        }
        if let previous=anchors[logicalSide], anchors[opposite(logicalSide)] == nil, let current, let alternate {
            let currentMatches=compatible(previous,current), alternateMatches=compatible(previous,alternate)
            guard currentMatches != alternateMatches else {
                reason="unknown_single_anchor_ambiguous"
                return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])
            }
            if alternateMatches { selectedChannel=other;reason="single_anchor_unique_alternate" }
            else { reason="single_anchor_unique_current" }
        }
        if let previous=anchors[logicalSide],let otherPrevious=anchors[opposite(logicalSide)],let current,let alternate {
            let same=compatible(previous,current) && compatible(otherPrevious,alternate)
            let swapped=compatible(previous,alternate) && compatible(otherPrevious,current)
            let sameA=cost(previous,current), sameB=cost(otherPrevious,alternate)
            let swapA=cost(previous,alternate), swapB=cost(otherPrevious,current)
            // Require each chain to prefer its partner by 0.015 diagonal, and the
            // whole assignment by 0.03; the old 0.18 gate is eligibility, not a tie.
            let sameClear=same && sameA+0.015<swapA && sameB+0.015<swapB && sameA+sameB+0.03<swapA+swapB
            let swapClear=swapped && swapA+0.015<sameA && swapB+0.015<sameB && swapA+swapB+0.03<sameA+sameB
            if sameClear == swapClear {reason="unknown_ambiguous_or_discontinuous";return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])}
            if swapClear {selectedChannel=other;reason="cross_channel_correspondence"} else {reason="same_channel_correspondence"}
        }
        let selected=chain(frame,selectedChannel),secondary=chain(frame,opposite(selectedChannel))
        if selected == nil {reason="unknown_target_missing"}
        if let selected,let target=anchors[logicalSide],!compatible(target,selected) {
            reason="unknown_target_discontinuous";return PoseFrame(timestamp:frame.timestamp,width:frame.width,height:frame.height,people:[])
        }
        // Learn the second chain only when distinguishable from the selected chain.
        if let selected,let secondary, distance(selected,secondary) >= 0.03 {
            anchors[logicalSide]=selected;anchors[opposite(logicalSide)]=secondary
        } else if let selected, anchors[opposite(logicalSide)] == nil {anchors[logicalSide]=selected}
        guard selectedChannel != logicalSide else {return frame}
        var result=frame
        for (target,source) in zip(logicalSide.joints,selectedChannel.joints) {
            result.people[0].points[target]=frame.people[0].points[source]
        }
        return result
    }
}
