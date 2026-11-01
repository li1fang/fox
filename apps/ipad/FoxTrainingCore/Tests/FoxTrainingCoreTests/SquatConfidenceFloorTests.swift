import Foundation
import XCTest
@testable import FoxTrainingCore

final class SquatConfidenceFloorTests: XCTestCase {
    func frame(_ t:Double,_ angle:Double,_ confidence:Double,missing:Bool=false)->PoseFrame {
        let a=angle * .pi/180
        var p:[PoseJoint:PosePoint]=[.rightHip:.init(x:0.6,y:0.8,confidence:confidence),
            .rightKnee:.init(x:0.6,y:0.5,confidence:confidence),
            .rightAnkle:.init(x:0.6+sin(a)*0.25*360/640,y:0.5+cos(a)*0.25,confidence:confidence)]
        if missing {p.removeValue(forKey:.rightAnkle)}
        return .init(timestamp:t,width:640,height:360,people:[.init(points:p)])
    }
    var cycle:[Double] {[Array(repeating:170.0,count:8),[150,130,110,95],Array(repeating:95.0,count:7),[110,130,150,170],Array(repeating:170.0,count:8)].flatMap{$0}}
    func consume(_ angles:[Double],confidence:Double,floor:SquatJointConfidenceFloor) throws -> SquatSelectedCounter {
        var c=SquatSelectedCounter(side:.right,jointConfidenceFloor:floor)
        for (i,a) in angles.enumerated(){try c.process(frame(Double(i)/10,a,confidence))}
        return c
    }
    func testExplicitFloorActuallyReachesSelectorAndCounterAndExactBoundary() throws {
        for floor in SquatJointConfidenceFloor.allCases {
            let c=try consume(cycle,confidence:floor.rawValue,floor:floor)
            XCTAssertEqual(c.events.count,1)
            XCTAssertEqual(c.jointConfidenceFloor,floor);XCTAssertEqual(c.counterJointConfidenceFloor,floor)
            XCTAssertEqual(try consume(cycle,confidence:floor.rawValue-0.001,floor:floor).events.count,0)
        }
        XCTAssertEqual(try consume(cycle,confidence:0.4,floor:.baseline).events.count,0)
        XCTAssertEqual(try consume(cycle,confidence:0.4,floor:.subjectGate).events.count,1)
        XCTAssertEqual(try consume(cycle,confidence:0.3,floor:.subjectGate).events.count,0)
        XCTAssertEqual(try consume(cycle,confidence:0.3,floor:.lowerProbe).events.count,1)
    }
    func testZeroMissingStaticAndHalfCyclesNeverProduceAnEvent() throws {
        for floor in SquatJointConfidenceFloor.allCases {
            XCTAssertEqual(try consume(cycle,confidence:0,floor:floor).events.count,0)
            for angles in [Array(repeating:170.0,count:40),Array(repeating:95.0,count:40),Array(cycle.prefix(18)),Array(cycle.suffix(20))] {
                XCTAssertEqual(try consume(angles,confidence:1,floor:floor).events.count,0)
            }
            var c=SquatSelectedCounter(side:.right,jointConfidenceFloor:floor)
            for (i,a) in cycle.enumerated(){try c.process(frame(Double(i)/10,a,1,missing:true))}
            XCTAssertEqual(c.events.count,0)
        }
    }
    func testLostPointDropsOnlyHalfAndReacquiresWithoutLosingCompletedCount() throws {
        for floor in SquatJointConfidenceFloor.allCases {
            var c=SquatSelectedCounter(side:.right,jointConfidenceFloor:floor),t=0.0
            for a in cycle {try c.process(frame(t,a,floor.rawValue));t+=0.1}
            XCTAssertEqual(c.events.count,1)
            for a in cycle.prefix(18) {try c.process(frame(t,a,floor.rawValue));t+=0.1}
            try c.process(frame(t,95,floor.rawValue,missing:true));t+=0.1
            for a in cycle.suffix(20) {try c.process(frame(t,a,floor.rawValue));t+=0.1}
            XCTAssertEqual(c.events.count,1,"No completion may be stitched across the missing joint")
            for a in cycle {try c.process(frame(t,a,floor.rawValue));t+=0.1}
            XCTAssertEqual(c.events.count,2)
        }
    }
    func testVariantIsExplicitAndAppValidationRejectsDevelopmentConfiguration() throws {
        for floor in [0.35,0.25] {
            let id="squat-side-joint-floor-\(Int(floor*100))-h1-v1"
            let binding=try VisionWorkflowBinding.load("squat",strategyID:id)
            XCTAssertEqual(binding.jointConfidenceFloor,floor)
            XCTAssertThrowsError(try binding.validate())
            try binding.validate(allowDevelopmentVariants:true)
            let confidence=floor==0.35 ? 0.4:0.3
            let frames=(Array(repeating:170.0,count:22)+cycle).enumerated().map {frame(Double($0.offset)/10,$0.element,confidence)}
            let replay=try VisionWorkflowReplay.run(action:"squat",side:.right,frames:frames,strategyID:id)
            XCTAssertEqual(replay.events.count,1,"The producer's binding must actually reach both gates")
            XCTAssertEqual(replay.binding.jointConfidenceFloor,floor)
            XCTAssertEqual(try VisionWorkflowReplay.run(action:"squat",side:.right,frames:frames).events.count,0)
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(binding)) as! [String:Any]
            object["jointConfidenceFloor"]=floor==0.35 ? 0.25:0.35
            let bad=try JSONDecoder().decode(VisionWorkflowBinding.self,from:JSONSerialization.data(withJSONObject:object))
            XCTAssertThrowsError(try bad.validate(allowDevelopmentVariants:true))
        }
        XCTAssertNil(try VisionWorkflowBinding.load("squat").jointConfidenceFloor)
    }
    func testSessionFactoryPersistsFrozenStrategyAndDropsInterruptedHalfCycle() throws {
        let strategy="squat-side-joint-floor-25-h1-v1"
        var chosen=try CountOnlySession(action:.squat,side:.right,originSeconds:0,source:.cachedPose,strategyID:strategy)
        var normal=try CountOnlySession(action:.squat,side:.right,originSeconds:0,source:.cachedPose)
        var time=0.0
        for a in cycle {
            let f=frame(time,a,0.3); try chosen.process(f);try normal.process(f);time+=0.1
        }
        XCTAssertEqual(chosen.evidence.observedCount,1);XCTAssertEqual(normal.evidence.observedCount,0)
        for a in cycle.prefix(18) {let f=frame(time,a,0.3);try chosen.process(f);time+=0.1}
        try chosen.process(frame(time,95,0.3,missing:true));time+=0.1
        for a in cycle.suffix(20) {try chosen.process(frame(time,a,0.3));time+=0.1}
        XCTAssertEqual(chosen.evidence.observedCount,1)
        for a in cycle {try chosen.process(frame(time,a,0.3));time+=0.1}
        XCTAssertEqual(chosen.evidence.observedCount,2)
        XCTAssertEqual(chosen.evidence.strategyID,strategy)
        XCTAssertEqual(chosen.evidence.algorithm,"squat-selected-count-only-h1-joint-floor-v1")
        try chosen.evidence.validate()
        let decoded=try JSONDecoder().decode(CountOnlyEvidence.self,from:JSONEncoder().encode(chosen.evidence))
        XCTAssertEqual(decoded,chosen.evidence);try decoded.validate()
        XCTAssertThrowsError(try CountOnlySession(action:.squat,side:.right,originSeconds:0,source:.cachedPose,strategyID:"squat-side-joint-floor-35-h1-v1"))
        XCTAssertThrowsError(try CountOnlySession(action:.curl,side:.right,originSeconds:0,source:.cachedPose,strategyID:strategy))
    }
    func testDefaultHalfFloorStrictlyMatchesFrozenOriginalProducerOnSyntheticInputs() throws {
        // Captured from the original4fc8 executable on these exact synthetic rows;
        // no executable/environment dependency and no regenerated expected values.
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/h1-frozen-synthetic-oracle.json")
        let oracle=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as! [String:Any]
        XCTAssertEqual(oracle["producerSHA256"] as? String,"4fc82805a6b31dc2ea1085bcf5a58ace54e83e8473874bad4c5fea9bd6668b33")
        XCTAssertEqual(oracle["inputClass"] as? String,"public_synthetic")
        let rows=try JSONSerialization.data(withJSONObject:oracle["frames"]!)
        let frames=try JSONDecoder().decode([PoseVideoRow].self,from:rows).map{try $0.frame()}
        let old=oracle["replay"] as! [String:Any]
        let current=try VisionWorkflowReplay.run(action:"squat",side:.right,frames:frames)
        XCTAssertEqual(current.events.count,2)
        XCTAssertEqual(current.binding.phaseStatus,"not_provided")
        let now=try JSONSerialization.jsonObject(with:JSONEncoder().encode(current)) as! [String:Any]
        for field in ["events","trace","resetCounts","sourceOriginSeconds","formalStartSeconds","side","timebase"] {
            XCTAssertEqual(old[field] as? NSObject,now[field] as? NSObject,field)
        }
    }
}
