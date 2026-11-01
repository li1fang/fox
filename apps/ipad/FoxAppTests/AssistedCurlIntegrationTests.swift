import Foundation
import XCTest
import FoxTrainingCore
@testable import Fox

@MainActor
final class AssistedCurlIntegrationTests: XCTestCase {
    private let cycle = Array(repeating: -1.0, count: 8) + [-0.8,-0.6,-0.4,-0.2,0,0.2,0.4,0.6,0.8,1] + Array(repeating: 1.0, count: 7) + [0.8,0.6,0.4,0.2,0,-0.2,-0.4,-0.6,-0.8,-1] + Array(repeating: -1.0, count: 8)
    private func makeStore(development: Bool = true, writer: ((Data,URL)throws ->Void)? = nil) throws -> (TrainingStore,VisionReplayClock) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AssistedApp-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let store=TrainingStore(archiveURL:root.appendingPathComponent("training.json"),diagnosticRoot:root.appendingPathComponent("diagnostic"),assistedDevelopmentEnabled:development,writer:writer)
        let clock=VisionReplayClock()
        store.workoutVision.controller.enableReplay(clock:clock)
        XCTAssertTrue(store.preparePractice(.curl,arm:.left,requestID:UUID()))
        store.setAssistedCurlEnabled(true)
        return (store,clock)
    }
    private func frame(_ v: Double, at t:Double, x:Double=0.5) -> PoseFrame {
        .init(timestamp:t,width:640,height:360,people:[.init(points:[
            .leftShoulder:.init(x:x,y:0.7),.leftElbow:.init(x:x,y:0.5),.leftWrist:.init(x:x,y:0.5+v*0.2)])])
    }
    private func feed(_ values:[Double],to store:TrainingStore,clock:VisionReplayClock,time:inout Double,bystander:Bool=false) {
        let controller=store.workoutVision.controller
        for (i,v) in values.enumerated() {
            clock.uptime=1000+time
            var value=frame(v,at:time)
            if bystander { let other=frame(-v,at:time,x:0.1).people[0];value.people=i%2==0 ? [other,value.people[0]]:[value.people[0],other] }
            controller.replayFrame(.init(frame:value,latencyMs:1,revision:1))
            time += i%2==0 ? 0.08:0.12
        }
    }
    func testUnqualifiedModeIsHiddenByDefaultAndCannotChangeOtherActions() throws {
        let (store,_)=try makeStore(development:false)
        defer { store.workoutVision.stop() }
        XCTAssertFalse(store.assistedCurlSelected);XCTAssertFalse(store.canChooseAssistedCurl)
        XCTAssertNil(store.clientState.assistedCurl)
        let (dev,_)=try makeStore()
        defer { dev.workoutVision.stop() }
        XCTAssertTrue(dev.assistedCurlSelected)
        XCTAssertTrue(dev.preparePractice(.lateralRaise,arm:.left,requestID:UUID()))
        dev.setAssistedCurlEnabled(true)
        XCTAssertFalse(dev.assistedCurlSelected)
        XCTAssertEqual(dev.session?.exercise.visualObservation?.exercise,.lateralRaise)
    }
    func testActualConsumerStartsWithoutPoseAndRetainsManualZeroAndChangedConfirmationOnReopen() throws {
        for confirmed in [0,4] {
            let (store,clock)=try makeStore();defer { store.workoutVision.stop() }
            store.workoutVision.prepare(arm:.left)
            XCTAssertEqual(store.session?.stage,.active)
            XCTAssertEqual(store.session?.observedAutomaticCount,0)
            var time=10.0
            feed(cycle,to:store,clock:clock,time:&time,bystander:true)
            XCTAssertEqual(store.session?.observedAutomaticCount,1)
            XCTAssertNil(store.session?.currentVisualEvidence)
            store.workoutVision.finish()
            let draft=TrainingFeedbackInput.initialDraft(session:try XCTUnwrap(store.session),saved:nil)
            XCTAssertEqual(draft.leftReps,"1");XCTAssertEqual(draft.rightReps,"")
            var saved=TrainingFeedbackDraft();saved.leftReps="0"
            XCTAssertEqual(TrainingFeedbackInput.initialDraft(session:try XCTUnwrap(store.session),saved:saved),saved)
            XCTAssertTrue(store.updateSession { try $0.submit(reps:nil,sideRepetitions:.init(left:confirmed),feedback:[],notes:"人工确认",at:clock.date) })
            XCTAssertTrue(store.confirmSummary(note:"公开合成辅助确认"))
            let reopened=TrainingStore(archiveURL:store.fileURL)
            XCTAssertTrue(reopened.archive.sessions.first?.isFinished == true)
            let record=try XCTUnwrap(reopened.archive.sessions.first?.records.first)
            XCTAssertEqual(record.assistedEvidence?.automaticCount,1)
            XCTAssertEqual(record.sideRepetitions?.left,confirmed)
            XCTAssertNil(record.visualEvidence);XCTAssertNil(record.rhythmAssessment)
            XCTAssertEqual(record.countingMethod,"manual_with_assisted")
            XCTAssertEqual(record.assistedEvidence?.runs.first?.evidence?.inputOriginSeconds,10)
        }
    }
    func testCameraDiscontinuityAndMissingJointKeepTrainingActiveDiscardHalfAndAutoRecover() throws {
        let (store,clock)=try makeStore();defer { store.workoutVision.stop() }
        store.workoutVision.prepare(arm:.left)
        var time=10.0;feed(cycle,to:store,clock:clock,time:&time)
        feed(Array(cycle.prefix(22)),to:store,clock:clock,time:&time)
        store.workoutVision.controller.replayDiscontinuity()
        XCTAssertEqual(store.session?.stage,.active)
        XCTAssertFalse(store.workoutVision.controller.needsRebind)
        feed(Array(cycle.suffix(18)),to:store,clock:clock,time:&time)
        XCTAssertEqual(store.session?.observedAutomaticCount,1)
        var missing=frame(1,at:time);missing.people[0].points.removeValue(forKey:.leftWrist)
        clock.uptime=1000+time;store.workoutVision.controller.replayFrame(.init(frame:missing,latencyMs:1,revision:1));time += 3
        feed(cycle,to:store,clock:clock,time:&time)
        XCTAssertEqual(store.session?.observedAutomaticCount,2)
        XCTAssertEqual(store.session?.stage,.active)
        XCTAssertEqual(store.session?.currentAssistedEvidence?.runs.count,2)
    }
    func testUnknownObservationDoesNotPrefillManualZeroAndOldCaptureCannotPolluteNewSet() throws {
        let (store,clock)=try makeStore();defer { store.workoutVision.stop() }
        store.workoutVision.prepare(arm:.left)
        let old=try XCTUnwrap(store.workoutVision.controller.replayCaptureID)
        store.workoutVision.finish()
        let draft=TrainingFeedbackInput.initialDraft(session:try XCTUnwrap(store.session),saved:nil)
        XCTAssertEqual(draft.leftReps,"");XCTAssertEqual(draft.rightReps,"")
        store.workoutVision.controller.replayFrame(.init(frame:frame(1,at:100),latencyMs:1,revision:1),capture:old)
        XCTAssertEqual(store.session?.observedAutomaticCount,0)
        XCTAssertTrue(store.updateSession {try $0.submit(reps:nil,sideRepetitions:.init(left:0),feedback:[],notes:"0",at:clock.date)})
        XCTAssertEqual(store.session?.records.first?.assistedEvidence?.automaticCount,0)
    }
    func testWriteFailureRetainsObservationAndRetryPersistsItWithoutPausingTraining() throws {
        var blocked=false
        let (store,clock)=try makeStore(writer:{ data,url in
            if blocked {throw CocoaError(.fileWriteOutOfSpace)}
            try data.write(to:url,options:.atomic)
        });defer {store.workoutVision.stop()}
        store.workoutVision.prepare(arm:.left)
        blocked=true
        var time=10.0;feed(cycle,to:store,clock:clock,time:&time)
        XCTAssertFalse(store.workoutVision.flush())
        XCTAssertEqual(store.session?.stage,.active)
        XCTAssertEqual(store.workoutVision.controller.assistedEvidence?.observedCount,1)
        blocked=false;XCTAssertTrue(store.workoutVision.flush())
        XCTAssertEqual(store.session?.observedAutomaticCount,1)
    }
    func testPresentationStopAndReopenKeepsCountAndStartsFreshObservationWithoutPausing() throws {
        let (store,clock)=try makeStore();defer {store.workoutVision.stop()}
        store.workoutVision.prepare(arm:.left)
        let first=store.session?.currentObservationId
        var time=10.0;feed(cycle,to:store,clock:clock,time:&time)
        feed(Array(cycle.prefix(22)),to:store,clock:clock,time:&time)
        store.stopPresentation(token:store.executionToken)
        XCTAssertEqual(store.session?.stage,.active)
        XCTAssertEqual(store.session?.observedAutomaticCount,1)
        clock.uptime=1000+time
        store.workoutVision.preview()
        XCTAssertNotEqual(store.session?.currentObservationId,first)
        feed(Array(cycle.suffix(18)),to:store,clock:clock,time:&time)
        XCTAssertEqual(store.session?.observedAutomaticCount,1)
        feed(cycle,to:store,clock:clock,time:&time)
        XCTAssertEqual(store.session?.observedAutomaticCount,2)
        XCTAssertEqual(store.session?.stage,.active)
        XCTAssertEqual(store.session?.currentAssistedEvidence?.runs.count,2)
    }

    func testSourceClockResetStartsNewOriginAndNeverPermanentlyRejectsNewFrames() throws {
        let (store,clock)=try makeStore();defer {store.workoutVision.stop()}
        store.workoutVision.prepare(arm:.left)
        var sourceTime=10.0;feed(cycle,to:store,clock:clock,time:&sourceTime)
        XCTAssertEqual(store.session?.observedAutomaticCount,1)
        store.workoutVision.controller.replayDiscontinuity()
        for (i,v) in cycle.enumerated() {
            clock.uptime += i%2==0 ? 0.08:0.12
            store.workoutVision.controller.replayFrame(.init(frame:frame(v,at:Double(i)*0.1),latencyMs:1,revision:1))
        }
        XCTAssertEqual(store.session?.observedAutomaticCount,2)
        XCTAssertEqual(store.session?.stage,.active)
        XCTAssertEqual(store.session?.currentAssistedEvidence?.runs.last?.evidence?.inputOriginSeconds,0)
    }

    func testDevelopmentSquatEntryUsesFrozenLegCounterAndPersistsManualConfirmation() throws {
        let (store,clock)=try makeStore();defer {store.workoutVision.stop()}
        XCTAssertTrue(store.prepareSquatPractice(requestID:UUID()))
        let squatSessionID=try XCTUnwrap(store.session?.id)
        XCTAssertEqual(TrainingActivity.allCases.count,4)
        XCTAssertTrue(store.countOnlySelected);XCTAssertFalse(store.assistedCurlSelected)
        store.workoutVision.prepare(arm:.left)
        XCTAssertEqual(store.session?.stage,.active)
        let angles=Array(repeating:170.0,count:5)+[150,130,110,95]+Array(repeating:95.0,count:4)+[110,130,150,170]+Array(repeating:170.0,count:5)
        for (i,angle) in angles.enumerated() {
            let r=angle * .pi/180;let time=10+Double(i)*0.1;clock.uptime=1000+time
            let points:[PoseJoint:PosePoint]=[.leftHip:.init(x:0.5,y:0.8),.leftKnee:.init(x:0.5,y:0.5),
                .leftAnkle:.init(x:0.5+sin(r)*0.25*360/640,y:0.5+cos(r)*0.25)]
            let value=PoseFrame(timestamp:time,width:640,height:360,people:[.init(points:points)])
            store.workoutVision.controller.replayFrame(.init(frame:value,latencyMs:1,revision:1))
        }
        XCTAssertEqual(store.session?.observedAutomaticCount,1)
        store.workoutVision.finish()
        XCTAssertEqual(TrainingFeedbackInput.initialDraft(session:try XCTUnwrap(store.session),saved:nil).reps,"1")
        XCTAssertTrue(store.updateSession {try $0.submit(reps:3,feedback:[],notes:"深蹲核对",at:clock.date)})
        XCTAssertTrue(store.confirmSummary(note:"公开合成深蹲确认"))
        let reopened=TrainingStore(archiveURL:store.fileURL)
        let savedSession=try XCTUnwrap(reopened.archive.sessions.first(where:{$0.id == squatSessionID}))
        XCTAssertTrue(savedSession.isFinished)
        let record=try XCTUnwrap(savedSession.records.first)
        XCTAssertEqual(record.assistedEvidence?.automaticCount,1);XCTAssertEqual(record.reps,3)
        XCTAssertEqual(record.assistedEvidence?.action,.squat);XCTAssertNil(record.rhythmAssessment)
        let (normal,_)=try makeStore(development:false);defer {normal.workoutVision.stop()}
        XCTAssertFalse(normal.prepareSquatPractice(requestID:UUID()))
    }

    func testPausedCountOnlyArchiveWithDevelopmentDisabledCanContinueManually() throws {
        let (original,clock)=try makeStore();defer {original.workoutVision.stop()}
        original.workoutVision.prepare(arm:.left)
        var time=10.0;feed(cycle,to:original,clock:clock,time:&time)
        XCTAssertTrue(original.workoutVision.pause())
        let originalEvents=try XCTUnwrap(original.session?.currentAssistedEvidence).runs.compactMap(\.evidence)
        let reopened=TrainingStore(archiveURL:original.fileURL,assistedDevelopmentEnabled:false)
        let preserved=try XCTUnwrap(reopened.session?.currentAssistedEvidence)
        XCTAssertEqual(preserved.runs.compactMap(\.evidence),originalEvents)
        let nextClock=VisionReplayClock(origin:clock.date.addingTimeInterval(1))
        reopened.workoutVision.controller.enableReplay(clock:nextClock)
        defer {reopened.workoutVision.stop()}
        XCTAssertFalse(reopened.countOnlySelected);XCTAssertFalse(reopened.usesVision);XCTAssertFalse(reopened.canEnableVision)
        reopened.workoutVision.prepare(arm:.left)
        XCTAssertEqual(reopened.session?.stage,.active)
        XCTAssertNil(reopened.session?.currentObservationId);XCTAssertNil(reopened.session?.currentVisualEvidence)
        XCTAssertEqual(reopened.session?.currentAssistedEvidence,preserved)
        reopened.workoutVision.finish()
        XCTAssertTrue(reopened.updateSession {try $0.submit(reps:nil,sideRepetitions:.init(left:2),feedback:[],notes:"人工继续",at:nextClock.date)})
        XCTAssertEqual(reopened.session?.records.first?.assistedEvidence?.automaticCount,1)
        XCTAssertEqual(reopened.session?.records.first?.sideRepetitions?.left,2)
    }

    func testRealCameraAdmissionResetsOnlyAtExplicitSourceDiscontinuity() throws {
        let camera=PoseCamera()
        XCTAssertTrue(camera.admitPosePTS(10))
        XCTAssertFalse(camera.admitPosePTS(0),"Unmarked out-of-order frames do not rebase the source")
        let sample=try VisionDiagnosticRecorder.syntheticSample(timestamp:0,width:16,height:16)
        let id=UUID()
        camera.deliverRawSample(sample,id:id,physicalSourceID:"public-source-a")
        camera.deliverRawSample(sample,id:id,physicalSourceID:"public-source-b")
        XCTAssertTrue(camera.admitPosePTS(0),"The actual pre-Vision admission must accept the new clock")
        XCTAssertFalse(camera.admitPosePTS(1.0/15))
        XCTAssertTrue(camera.admitPosePTS(2.0/15))
    }

    func testSquatStrategySurvivesNoFramePresentationRestartAndDiscontinuity() throws {
        for qualified in [false,true] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("SquatNoFrame-\(UUID())")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            addTeardownBlock {try? FileManager.default.removeItem(at:root)}
            let store=TrainingStore(archiveURL:root.appendingPathComponent("training.json"),diagnosticRoot:root.appendingPathComponent("diagnostic"),assistedDevelopmentEnabled:!qualified,admittedCountOnlyActions:qualified ? [.squat]:[])
            let clock=VisionReplayClock();store.workoutVision.controller.enableReplay(clock:clock)
            defer {store.workoutVision.stop()}
            XCTAssertTrue(store.prepareSquatPractice(side:.right,requestID:UUID()))
            store.workoutVision.prepare(arm:.right)
            XCTAssertEqual(store.session?.stage,.active)
            XCTAssertNil(store.session?.currentAssistedEvidence?.runs.first?.evidence)
            let expected = qualified ? "squat-side-joint-floor-25-h1-v1" : nil
            XCTAssertEqual(store.session?.currentAssistedEvidence?.runs.first?.declaredStrategyID,expected)
            let beforeFrame=try LocalTrainingRepository.decoder().decode(TrainingArchive.self,from:Data(contentsOf:store.fileURL))
            try beforeFrame.validate()
            XCTAssertEqual(beforeFrame.currentSession?.currentAssistedEvidence?.runs.first?.declaredStrategyID,expected)
            store.stopPresentation(token:store.executionToken)
            XCTAssertEqual(store.session?.stage,.active)
            store.workoutVision.preview()
            store.workoutVision.controller.replayDiscontinuity()
            XCTAssertEqual(store.session?.currentAssistedEvidence?.runs.last?.declaredStrategyID,expected)
            XCTAssertEqual(store.session?.stage,.active)
            let angles=Array(repeating:170.0,count:8)+[150,130,110,95]+Array(repeating:95.0,count:8)+[110,130,150,170]+Array(repeating:170.0,count:8)
            for (i,angle) in angles.enumerated() {
                let a=angle * .pi/180,t=10+Double(i)*0.1
                let points:[PoseJoint:PosePoint]=[.rightHip:.init(x:0.6,y:0.8,confidence:0.3),.rightKnee:.init(x:0.6,y:0.5,confidence:0.3),.rightAnkle:.init(x:0.6+sin(a)*0.25*360/640,y:0.5+cos(a)*0.25,confidence:0.3)]
                clock.uptime=1000+t
                store.workoutVision.controller.replayFrame(.init(frame:.init(timestamp:t,width:640,height:360,people:[.init(points:points)]),latencyMs:0,revision:1))
            }
            XCTAssertTrue(store.workoutVision.flush(),"qualified=\(qualified), error=\(store.errorMessage ?? "nil"), reason=\(store.workoutVision.controller.assistedReason), runtime=\(String(describing:store.workoutVision.controller.assistedEvidence)), runs=\(String(describing:store.session?.currentAssistedEvidence?.runs))")
            let facts=try XCTUnwrap(store.session?.currentAssistedEvidence?.runs.last?.evidence,"qualified=\(qualified), error=\(store.errorMessage ?? "nil")")
            XCTAssertEqual(facts.strategyID,qualified ? "squat-side-joint-floor-25-h1-v1":nil)
            XCTAssertEqual(facts.observedCount,qualified ? 1:0)
            XCTAssertEqual(store.session?.stage,.active);XCTAssertNil(store.session?.currentVisualEvidence)
        }
    }

    func testQualifiedSquatNormalEntryUsesFrozenStrategyAndPreservesSide() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("QualifiedSquat-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        let store=TrainingStore(archiveURL:root.appendingPathComponent("training.json"),diagnosticRoot:root.appendingPathComponent("diagnostic"),assistedDevelopmentEnabled:false,admittedCountOnlyActions:[.squat])
        let clock=VisionReplayClock();store.workoutVision.controller.enableReplay(clock:clock)
        defer {store.workoutVision.stop()}
        XCTAssertTrue(store.prepareSquatPractice(side:.right,requestID:UUID()))
        store.workoutVision.prepare(arm:.right)
        XCTAssertEqual(store.session?.stage,.active)
        let angles=Array(repeating:170.0,count:8)+[150,130,110,95]+Array(repeating:95.0,count:8)+[110,130,150,170]+Array(repeating:170.0,count:8)
        for (i,angle) in angles.enumerated() {
            let a=angle * .pi/180,t=10+Double(i)*0.1
            let points:[PoseJoint:PosePoint]=[.rightHip:.init(x:0.6,y:0.8,confidence:0.3),.rightKnee:.init(x:0.6,y:0.5,confidence:0.3),.rightAnkle:.init(x:0.6+sin(a)*0.25*360/640,y:0.5+cos(a)*0.25,confidence:0.3)]
            clock.uptime=1000+t
            store.workoutVision.controller.replayFrame(.init(frame:.init(timestamp:t,width:640,height:360,people:[.init(points:points)]),latencyMs:0,revision:1))
        }
        XCTAssertTrue(store.workoutVision.flush())
        let facts=try XCTUnwrap(store.session?.currentAssistedEvidence?.runs.first?.evidence)
        XCTAssertEqual(facts.observedCount,1)
        XCTAssertEqual(facts.strategyID,"squat-side-joint-floor-25-h1-v1")
        XCTAssertEqual(facts.side,.right);XCTAssertEqual(store.session?.stage,.active)
        let reopened=TrainingStore(archiveURL:store.fileURL,assistedDevelopmentEnabled:false,admittedCountOnlyActions:[.squat])
        let saved=try XCTUnwrap(reopened.session?.currentAssistedEvidence?.runs.first?.evidence)
        XCTAssertEqual(saved.strategyID,facts.strategyID);XCTAssertEqual(saved.side,.right)
        XCTAssertNil(reopened.session?.currentVisualEvidence)
    }

    func testSquatAdmissionDoesNotAuthorizeCurlAndRestoredCurlContinuesManually() throws {
        let (original,clock)=try makeStore();defer {original.workoutVision.stop()}
        original.workoutVision.prepare(arm:.left)
        var time=10.0;feed(cycle,to:original,clock:clock,time:&time)
        XCTAssertTrue(original.workoutVision.pause())
        let reopened=TrainingStore(archiveURL:original.fileURL,assistedDevelopmentEnabled:false,admittedCountOnlyActions:[.squat,.curl])
        let preserved=try XCTUnwrap(reopened.session?.currentAssistedEvidence)
        reopened.workoutVision.controller.enableReplay(clock:clock)
        defer {reopened.workoutVision.stop()}
        XCTAssertFalse(reopened.countOnlySelected);XCTAssertFalse(reopened.canChooseAssistedCurl)
        reopened.workoutVision.prepare(arm:.left)
        XCTAssertEqual(reopened.session?.stage,.active)
        XCTAssertEqual(reopened.session?.currentAssistedEvidence,preserved)
        XCTAssertNil(reopened.session?.currentObservationId)
        XCTAssertTrue(reopened.enter(.squat(.right,UUID())))
        XCTAssertTrue(reopened.countOnlySelected);XCTAssertFalse(reopened.assistedCurlSelected)
        reopened.workoutVision.prepare(arm:.right)
        XCTAssertEqual(reopened.session?.currentAssistedEvidence?.action,.squat)
        XCTAssertTrue(reopened.preparePractice(.curl,requestID:UUID()))
        XCTAssertFalse(reopened.assistedCurlSelected);XCTAssertFalse(reopened.canChooseAssistedCurl)
        XCTAssertEqual(reopened.session?.exercise.visualObservation?.exercise,.curl)
    }

}
