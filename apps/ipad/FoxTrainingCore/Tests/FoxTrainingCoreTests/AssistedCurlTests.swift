import XCTest
import FoxTrainingCore

final class AssistedCurlTests: XCTestCase {
    let cycle = Array(repeating: -1.0, count: 8) + [-0.8,-0.6,-0.4,-0.2,0,0.2,0.4,0.6,0.8,1] + Array(repeating: 1.0, count: 7) + [0.8,0.6,0.4,0.2,0,-0.2,-0.4,-0.6,-0.8,-1] + Array(repeating: -1.0, count: 8)
    func frame(_ value: Double, _ time: Double, x: Double = 0.5) -> PoseFrame {
        PoseFrame(timestamp: time, width: 640, height: 360, people: [BodyPose(points: [
            .leftShoulder: PosePoint(x:x,y:0.7), .leftElbow:PosePoint(x:x,y:0.5),
            .leftWrist:PosePoint(x:x,y:0.5+value*0.2)])])
    }
    func testVariablePTSCountsWithoutInventingUniformFramesAndStrictDefaultRemains() throws {
        var variable = FrontalCurlCounter(side:.left,originSeconds:10,variant:.high040,countPolicy:.observedReturn,expectedFrameInterval:0.1,timingPolicy:.variablePTS)
        var strict = FrontalCurlCounter(side:.left,originSeconds:10,variant:.high040,countPolicy:.observedReturn,expectedFrameInterval:0.1)
        var t=10.0
        for (i,v) in cycle.enumerated() {
            let f=frame(v,t);try variable.process(f);try strict.process(f);t += i%2 == 0 ? 0.08 : 0.12
        }
        XCTAssertEqual(variable.events.count,1)
        XCTAssertEqual(strict.events.count,0)
        XCTAssertGreaterThan(variable.events.first?.completedAtSeconds ?? 0,2)
    }

    func feed(_ values:[Double], _ session:inout AssistedCurlSession, _ time:inout Double, bystander:Bool=false) throws {
        for (i,v) in values.enumerated() {
            var f=frame(v,time)
            if bystander { let other=frame(-v,time,x:0.1).people[0];f.people=i%2==0 ? [other,f.people[0]]:[f.people[0],other] }
            try session.process(f);time += i%2==0 ? 0.08:0.12
        }
    }
    func testCentralPersonWithBystanderAndReorderedDetectionsCounts() throws {
        var s=try AssistedCurlSession(side:.left,originSeconds:0);var t=0.0
        try feed(cycle,&s,&t,bystander:true)
        XCTAssertEqual(s.evidence.observedCount,1);XCTAssertEqual(s.evidence.segments.count,1)
        try s.evidence.validate()
    }
    func testRealMissingDropsPartialKeepsCountAndAutomaticallyRecovers() throws {
        var s=try AssistedCurlSession(side:.left,originSeconds:0);var t=0.0
        try feed(cycle,&s,&t);try feed(Array(cycle.prefix(22)),&s,&t)
        var missing=frame(1,t);missing.people[0].points.removeValue(forKey:.leftWrist)
        try s.process(missing);t += 0.1
        XCTAssertEqual(s.evidence.observedCount,1)
        try feed(Array(cycle.suffix(18)),&s,&t);XCTAssertEqual(s.evidence.observedCount,1)
        try feed(cycle,&s,&t);XCTAssertEqual(s.evidence.observedCount,2)
        XCTAssertGreaterThan(s.evidence.segments.count,1);try s.evidence.validate()
    }
    func testLongSourceGapAndHostInterruptionNeverRequireManualRebind() throws {
        for hostInterrupt in [false,true] {
            var s=try AssistedCurlSession(side:.left,originSeconds:0);var t=0.0
            try feed(cycle,&s,&t);try feed(Array(cycle.prefix(22)),&s,&t)
            if hostInterrupt {try s.inputInterrupted(at:t)}
            t += 3
            try feed(Array(cycle.suffix(18)),&s,&t);XCTAssertEqual(s.evidence.observedCount,1)
            try feed(cycle,&s,&t);XCTAssertEqual(s.evidence.observedCount,2)
            try s.evidence.validate()
        }
    }
    func testDuplicateObservationDoesNotDoubleCountOrRequireSingleCandidate() throws {
        var s=try AssistedCurlSession(side:.left,originSeconds:0)
        for (i,v) in cycle.enumerated() {var f=frame(v,Double(i)*0.1);f.people.append(f.people[0]);try s.process(f)}
        XCTAssertEqual(s.evidence.observedCount,1)
    }
    func testDistantReplacementCannotFinishPreviousPersonsHalfCycle() throws {
        var s=try AssistedCurlSession(side:.left,originSeconds:0);var t=0.0
        try feed(Array(cycle.prefix(22)),&s,&t)
        for v in cycle.suffix(18) {try s.process(frame(v,t,x:0.7));t += 0.1}
        XCTAssertEqual(s.evidence.observedCount,0)
        for v in cycle {try s.process(frame(v,t,x:0.7));t += 0.1}
        XCTAssertEqual(s.evidence.observedCount,1)
    }
    func testFormalStartDoesNotIncludePreparationOrCarryHalfCycle() throws {
        let boundary=Double(cycle.count+22)*0.1
        var s=try AssistedCurlSession(side:.left,originSeconds:0,formalStartSeconds:boundary)
        let values=cycle+cycle+cycle
        for (i,v) in values.enumerated() {try s.process(frame(v,Double(i)*0.1))}
        XCTAssertEqual(s.evidence.observedCount,1)
        XCTAssertTrue(s.evidence.events.allSatisfy{$0.completedAtSeconds >= boundary})
        try s.evidence.validate()
    }
    func testStaticHalfCycleAndMissingInputProduceNoEvents() throws {
        for values in [Array(repeating:-1.0,count:100),Array(repeating:1.0,count:100),Array(cycle.prefix(22))] {
            var s=try AssistedCurlSession(side:.left,originSeconds:0);var t=0.0;try feed(values,&s,&t)
            XCTAssertEqual(s.evidence.observedCount,0)
        }
    }
    func testInvalidInputClearsPartialAndClosedSessionRejectsStaleCallbacks() throws {
        var s=try AssistedCurlSession(side:.left,originSeconds:0);var t=0.0
        try feed(Array(cycle.prefix(22)),&s,&t)
        XCTAssertThrowsError(try s.process(frame(1,0)))
        try feed(Array(cycle.suffix(18)),&s,&t);XCTAssertEqual(s.evidence.observedCount,0)
        try feed(cycle,&s,&t);XCTAssertEqual(s.evidence.observedCount,1)
        s.close();XCTAssertThrowsError(try s.process(frame(-1,t)));try s.evidence.validate()
    }
    func testGeometryChangeBreaksPartialButContinuesNewCycle() throws {
        var s=try AssistedCurlSession(side:.left,originSeconds:0);var t=0.0
        try feed(Array(cycle.prefix(22)),&s,&t)
        for v in cycle.suffix(18) {var f=frame(v,t);f.width=1280;f.height=720;try s.process(f);t += 0.1}
        XCTAssertEqual(s.evidence.observedCount,0)
        for v in cycle {var f=frame(v,t);f.width=1280;f.height=720;try s.process(f);t += 0.1}
        XCTAssertEqual(s.evidence.observedCount,1);try s.evidence.validate()
    }
    func testCountOnlyRecordRoundTripsAndConfirmationNeverRewritesObservation() throws {
        var s=try AssistedCurlSession(side:.left,originSeconds:0);var t=0.0;try feed(cycle,&s,&t)
        for confirmed in [nil,0,1,7] as [Int?] {
            let record=try AssistedCurlRecord(evidence:s.evidence,confirmedCount:confirmed)
            let data=try JSONEncoder().encode(record)
            XCTAssertEqual(try AssistedCurlRecord.decode(data),record)
            XCTAssertEqual(record.evidence.observedCount,1);XCTAssertEqual(record.confirmedCount,confirmed)
            XCTAssertEqual(record.evidence.phaseStatus,"not_provided")
            XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("liftSeconds"))
        }
        XCTAssertThrowsError(try AssistedCurlRecord(evidence:s.evidence,confirmedCount:-1))
    }
    func testPersistedUnknownSchemaAndInvalidSegmentAreRejected() throws {
        var s=try AssistedCurlSession(side:.left,originSeconds:0);var t=0.0;try feed(cycle,&s,&t)
        let original=try JSONEncoder().encode(AssistedCurlRecord(evidence:s.evidence))
        for kind in 0...2 {
            var object=try JSONSerialization.jsonObject(with:original) as! [String:Any]
            if kind==0 {object["schema"]="future"}
            else {var e=object["evidence"] as! [String:Any]
                if kind==1 {e["phaseStatus"]="measured"}
                else {var events=e["events"] as! [[String:Any]];events[0]["segmentID"]=99;e["events"]=events}
                object["evidence"]=e
            }
            XCTAssertThrowsError(try AssistedCurlRecord.decode(JSONSerialization.data(withJSONObject:object)))
        }
    }

    func testConflictingCentralPeopleCannotSpliceTwoHalfCyclesWhenArrayOrderChanges() throws {
        var s=try AssistedCurlSession(side:.left,originSeconds:0)
        for (i,v) in cycle.enumerated() {
            let t=Double(i)*0.1
            let a=frame(i<25 ? v:1,t).people[0]
            let b=frame(i<25 ? 1:v,t).people[0]
            var f=frame(v,t);f.people=i<25 ? [a,b]:[b,a]
            try s.process(f)
        }
        XCTAssertEqual(s.evidence.observedCount,0)
        var t=Double(cycle.count)*0.1
        try feed(cycle,&s,&t)
        XCTAssertEqual(s.evidence.observedCount,1)
    }
}
