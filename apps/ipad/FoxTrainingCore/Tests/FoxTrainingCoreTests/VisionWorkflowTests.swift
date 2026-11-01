import Foundation
import XCTest
@testable import FoxTrainingCore

final class VisionWorkflowTests: XCTestCase {
    func frame(_ t:Double,_ angle:Double,close:Bool=false,x:Double=0.6)->PoseFrame {
        let r=angle * .pi/180
        var p:[PoseJoint:PosePoint]=[.rightHip:.init(x:x,y:0.8),.rightKnee:.init(x:x,y:0.5),
            .rightAnkle:.init(x:x+sin(r)*0.25*360/640,y:0.5+cos(r)*0.25)]
        if close {p.removeValue(forKey:.rightKnee);p.removeValue(forKey:.rightAnkle)}
        return .init(timestamp:t,width:640,height:360,people:[.init(points:p)])
    }
    func testActionRegistryUsesOriginalSideCurlAndFrozenSquatWithoutEnablingCapability() throws {
        let squat=try VisionActionBinding.load("squat"),curl=try VisionActionBinding.load("curl")
        XCTAssertEqual(squat.algorithm,CountOnlyAction.squat.algorithm)
        XCTAssertEqual(squat.phaseStatus,"not_provided")
        XCTAssertEqual(curl.algorithm,try MotionStrategy.load(.curl).algorithm)
        XCTAssertEqual(curl.consumerMode,"controller")
        XCTAssertThrowsError(try VisionActionBinding.load("frontalCurl"))
        XCTAssertFalse(squat.label.contains("徒手"))
        XCTAssertFalse(CountOnlyAction.squat.label.contains("徒手"),"Holding an object does not define a different movement")
    }
    func testTouchScreenPartialAndNearScreenMissingLegsDoNotCountOrLockTheFirstWholeCycle() throws {
        let angles=[Array(repeating:170.0,count:4),Array(repeating:95.0,count:20),Array(repeating:170.0,count:7),
            Array(repeating:95.0,count:9),Array(repeating:170.0,count:8)].flatMap {$0}
        var frames=angles.enumerated().map{frame(Double($0.offset)/10,$0.element)}
        // The person near the screen cannot supply the frozen complete leg chain.
        for i in 0..<20 {frames[i]=frame(Double(i)/10,95,close:true,x:0.3)}
        let result=try VisionWorkflowReplay.run(action:"squat",side:.right,frames:frames)
        XCTAssertEqual(result.formalStartSeconds,2)
        XCTAssertEqual(result.events.count,1,"A partial already-low start cannot become a repetition; the first real high-low-high must survive")
        XCTAssertEqual(result.binding.phaseStatus,"not_provided")
        XCTAssertNil(result.events.first?.returnGateAtSourcePTSSeconds,"Debounce confirmation must not fabricate a return endpoint")
        XCTAssertNil(result.legacyRepetitions)
    }
    func testRawPTSOrderingAndCompleteInputBoundaryRemainRequired() throws {
        let frames=(0..<40).map{frame(Double($0)/10,170)}
        XCTAssertThrowsError(try VisionWorkflowReplay.run(action:"squat",side:.right,frames:Array(frames.prefix(10))))
        var duplicate=frames;duplicate[20]=frames[19]
        XCTAssertThrowsError(try VisionWorkflowReplay.run(action:"squat",side:.right,frames:duplicate))
        XCTAssertEqual(try VisionWorkflowReplay.run(action:"squat",side:.right,frames:frames).events.count,0)
    }
    func testResetIsNotHiddenBySameFrameValidGeometryAndOriginalClockIsRequired() throws {
        var frames=(0..<40).map{frame(Double($0)/10,170)}
        frames[30].width=1280;frames[30].height=720
        let result=try VisionWorkflowReplay.run(action:"squat",side:.right,frames:frames)
        XCTAssertEqual(result.trace[30].reason,"observed")
        XCTAssertTrue(result.trace[30].reset)
        XCTAssertEqual(result.trace[30].resetReason,"geometry_changed")
        let clock=(0..<40).map{"{\"value\":\"\($0)\",\"timescale\":10,\"epoch\":\"0\"}"}.joined(separator:"\n")
        try VisionWorkflowCache.validateClock(Data(clock.utf8),frames:frames)
        XCTAssertThrowsError(try VisionWorkflowCache.validateClock(Data("{\"value\":\"0\",\"timescale\":10,\"epoch\":\"0\"}".utf8),frames:frames))
    }
}
