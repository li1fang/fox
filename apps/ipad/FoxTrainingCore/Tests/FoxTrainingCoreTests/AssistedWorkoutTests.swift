import Foundation
import XCTest
@testable import FoxTrainingCore

final class AssistedWorkoutTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_234_000)
    func plan() -> TrainingPlan {
        var exercise = Exercise(id: "dumbbell_curl", name: "弯举", sets: [SetTarget(setIndex: 1, reps: 5, weight: 2.5, rest: 0)])
        exercise.visualObservation = WorkoutObservationSettings(exercise: .curl, arm: .left, bodyView: .side)
        exercise.repetitionBasis = .perSide
        exercise.targetSide = .left
        return TrainingPlan(focus: "Assisted development", exercises: [exercise])
    }
    func testVersionedCountOnlyArchiveRetainsEvidenceInsteadOfSilentlyDroppingIt() throws {
        let session = try TrainingSession(plan: plan(), now: now)
        var archive = TrainingArchive(); archive.schemaVersion = 2
        archive.sessions = [session]; archive.foregroundSessionID = session.id
        var object = try JSONSerialization.jsonObject(with: LocalTrainingRepository.encoder().encode(archive)) as! [String: Any]
        object["schemaVersion"] = 3
        var sessions = object["sessions"] as! [[String: Any]]
        let binding = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(session.currentSetBinding)))
        sessions[0]["currentAssistedEvidence"] = ["schema": "fox.workout_count_only.v1", "binding": binding,
            "side": "left", "action": "curl", "source": "fixture", "runs": []] as [String: Any]
        object["sessions"] = sessions
        let decoded = try LocalTrainingRepository.decoder().decode(TrainingArchive.self, from: JSONSerialization.data(withJSONObject: object))
        try decoded.validate()
        let reencoded = try JSONSerialization.jsonObject(with: LocalTrainingRepository.encoder().encode(decoded)) as! [String: Any]
        let saved = (reencoded["sessions"] as! [[String: Any]])[0]
        XCTAssertNotNil(saved["currentAssistedEvidence"], "A supported reader must preserve count-only evidence")
    }
    let cycle = Array(repeating: -1.0, count: 8) + [-0.8,-0.6,-0.4,-0.2,0,0.2,0.4,0.6,0.8,1] + Array(repeating: 1.0, count: 7) + [0.8,0.6,0.4,0.2,0,-0.2,-0.4,-0.6,-0.8,-1] + Array(repeating: -1.0, count: 8)
    func observed(origin: Double = 1000) throws -> AssistedCurlEvidence {
        var runtime = try AssistedCurlSession(side: .left, originSeconds: origin)
        var t=origin
        for (i,v) in cycle.enumerated() {
            let points: [PoseJoint: PosePoint] = [.leftShoulder:.init(x:0.5,y:0.7),.leftElbow:.init(x:0.5,y:0.5),.leftWrist:.init(x:0.5,y:0.5+v*0.2)]
            try runtime.process(.init(timestamp:t,width:640,height:360,people:[.init(points:points)]))
            t += i%2 == 0 ? 0.08 : 0.12
        }
        XCTAssertEqual(runtime.evidence.observedCount,1)
        return runtime.evidence
    }
    func file() throws -> URL {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("AssistedWorkout-\(UUID())")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:dir) }
        return dir.appendingPathComponent("training.json")
    }
    func testManualUnknownZeroAndCorrectionRemainIndependentAcrossRepositoryReload() throws {
        let evidence=try observed()
        for confirmed: Int? in [nil,0,1,4] {
            let url=try file();let repo=try LocalTrainingRepository(fileURL:url)
            try repo.start(plan:plan(),at:now)
            let before=try Data(contentsOf:url)
            let id=repo.archive.currentSession!.id
            try repo.updateSession(id:id) { session in
                let observation=try session.beginAssistedCurl(side:.left,source:.fixture,at:now)
                try session.updateAssistedCurl(binding:XCTUnwrap(session.currentSetBinding),observationId:observation,
                    evidence:evidence,appleRevision:1,at:now.addingTimeInterval(8))
                if let confirmed {
                    try session.finishSet(at:now.addingTimeInterval(9))
                    try session.submit(reps:nil,sideRepetitions:.init(left:confirmed),feedback:[],notes:"核对",at:now.addingTimeInterval(10))
                } else { try session.endEarly(at:now.addingTimeInterval(9)) }
            }
            let reopened=try LocalTrainingRepository(fileURL:url)
            let record=try XCTUnwrap(reopened.archive.sessions.first?.records.first)
            XCTAssertEqual(record.sideRepetitions?.left,confirmed)
            XCTAssertEqual(record.assistedEvidence?.automaticCount,1)
            XCTAssertEqual(record.assistedEvidence?.runs.first?.evidence?.curlEvidence,evidence)
            XCTAssertNil(record.visualEvidence);XCTAssertNil(record.rhythmAssessment);XCTAssertNil(record.formAssessment)
            XCTAssertEqual(record.countingMethod,confirmed == nil ? "unconfirmed":"manual_with_assisted")
            XCTAssertEqual(record.countingEvidenceVersion,2);XCTAssertEqual(reopened.archive.schemaVersion,3)
            let backups=try FileManager.default.contentsOfDirectory(at:url.deletingLastPathComponent(),includingPropertiesForKeys:nil)
                .filter {$0.lastPathComponent.hasPrefix(url.lastPathComponent+".pre-assisted-v2-") && $0.lastPathComponent.hasSuffix("-original")}
            XCTAssertEqual(backups.count,1)
            XCTAssertEqual(try Data(contentsOf:XCTUnwrap(backups.first)),before)
        }
    }
    func testResumeUsesNewRunAndRejectsOldCallbacksAndRewrittenPrefix() throws {
        var session=try TrainingSession(plan:plan(),now:now)
        let old=try session.beginAssistedCurl(side:.left,source:.fixture,at:now)
        let binding=try XCTUnwrap(session.currentSetBinding)
        let first=try observed()
        try session.updateAssistedCurl(binding:binding,observationId:old,evidence:first,appleRevision:1,at:now.addingTimeInterval(8))
        var changed=try JSONSerialization.jsonObject(with:JSONEncoder().encode(first)) as! [String:Any]
        var events=changed["events"] as! [[String:Any]];events[0]["completedAtSeconds"]=4.1;changed["events"]=events
        let rewritten=try JSONDecoder().decode(AssistedCurlEvidence.self,from:JSONSerialization.data(withJSONObject:changed))
        XCTAssertThrowsError(try session.updateAssistedCurl(binding:binding,observationId:old,evidence:rewritten,appleRevision:1,at:now.addingTimeInterval(9)))
        try session.pause(at:now.addingTimeInterval(10))
        let fresh=try session.beginAssistedCurl(side:.left,source:.fixture,at:now.addingTimeInterval(20))
        XCTAssertNotEqual(old,fresh)
        XCTAssertThrowsError(try session.updateAssistedCurl(binding:binding,observationId:old,evidence:first,appleRevision:1,at:now.addingTimeInterval(21)))
        try session.updateAssistedCurl(binding:binding,observationId:fresh,evidence:observed(origin:2000),appleRevision:1,at:now.addingTimeInterval(28))
        XCTAssertEqual(session.observedAutomaticCount,2);XCTAssertEqual(session.currentAssistedEvidence?.runs.count,2)
        XCTAssertNil(session.currentVisualEvidence)
    }
    func testProcessRestartSealsObservationAndKeepsCompletedEvents() throws {
        let url=try file();let repo=try LocalTrainingRepository(fileURL:url)
        try repo.start(plan:plan(),at:now)
        try repo.updateSession(id:repo.archive.currentSession!.id) { session in
            let id=try session.beginAssistedCurl(side:.left,source:.fixture,at:now)
            try session.updateAssistedCurl(binding:XCTUnwrap(session.currentSetBinding),observationId:id,evidence:observed(),appleRevision:1,at:now.addingTimeInterval(8))
        }
        let reopened=try LocalTrainingRepository(fileURL:url)
        let session=try XCTUnwrap(reopened.archive.currentSession)
        XCTAssertEqual(session.stage,.paused);XCTAssertNil(session.currentObservationId)
        XCTAssertEqual(session.observedAutomaticCount,1)
        XCTAssertEqual(session.currentAssistedEvidence?.runs.last?.endReason,.restart)
        XCTAssertEqual(session.elapsed(at:now.addingTimeInterval(100)),8)
    }
    func testLegacyRouteRemainsVersionTwoAndFutureSchemaCannotBeRead() throws {
        let url=try file();let repo=try LocalTrainingRepository(fileURL:url)
        try repo.start(plan:plan(),at:now)
        XCTAssertEqual(repo.archive.schemaVersion,2)
        XCTAssertNil(repo.archive.currentSession?.currentAssistedEvidence)
        let bytes=try Data(contentsOf:url)
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("assistedEvidence"))
        var future=repo.archive;future.schemaVersion=4
        XCTAssertThrowsError(try future.validate())
        var settings=WorkoutObservationSettings(exercise:.curl,arm:.left,bodyView:.front)
        XCTAssertThrowsError(try settings.validate())
        settings.bodyView = .side;XCTAssertNoThrow(try settings.validate())
    }

    func testCountOnlyGuidanceDoesNotInventPhaseEvenIfPlannedModeWasStored() throws {
        let input=GuidanceInput(context:.init(sessionID:"s",attemptID:"a",observationID:"o"),time:1,stage:.active,
            exercise:.curl,mode:.planned,count:1,targetReps:5,motion:nil,
            tempo:[.init("lift",seconds:3,visual:"expand")],elapsed:1)
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(input)) as! [String:Any]
        object["countOnly"]=true
        let decoded=try JSONDecoder().decode(GuidanceInput.self,from:JSONSerialization.data(withJSONObject:object))
        var policy=GuidancePolicy();let output=policy.update(decoded)
        XCTAssertFalse(output.presentation.isMoving)
        XCTAssertNil(output.presentation.phaseToken)
        XCTAssertFalse(output.cues.contains(where:{$0.kind == .phase}))
    }

    func testSquatUsesSameCountOnlyRepositoryContractWithoutPhaseFabrication() throws {
        var runtime=try CountOnlySession(action:.squat,side:.left,originSeconds:1000,source:.cachedPose)
        let angles=Array(repeating:170.0,count:5)+[150,130,110,95]+Array(repeating:95.0,count:4)+[110,130,150,170]+Array(repeating:170.0,count:5)
        for (i,angle) in angles.enumerated() {
            let r=angle * .pi/180
            let points:[PoseJoint:PosePoint]=[.leftHip:.init(x:0.5,y:0.8),.leftKnee:.init(x:0.5,y:0.5),
                .leftAnkle:.init(x:0.5+sin(r)*0.25*360/640,y:0.5+cos(r)*0.25)]
            try runtime.process(.init(timestamp:1000+Double(i)*0.1,width:640,height:360,people:[.init(points:points)]))
        }
        XCTAssertEqual(runtime.evidence.observedCount,1)
        var exercise=Exercise(id:"bodyweight_squat",name:"深蹲",sets:[SetTarget(setIndex:1,reps:5)])
        exercise.targetSets[0].weightUnit="bodyweight";exercise.repetitionBasis = .total
        let plan=TrainingPlan(focus:"Squat",exercises:[exercise])
        let url=try file();let repo=try LocalTrainingRepository(fileURL:url);try repo.start(plan:plan,at:now)
        try repo.updateSession(id:repo.archive.currentSession!.id) { session in
            let id=try session.beginCountOnly(action:.squat,side:.left,source:.fixture,at:now)
            try session.updateCountOnly(binding:XCTUnwrap(session.currentSetBinding),observationId:id,evidence:runtime.evidence,appleRevision:1,at:now.addingTimeInterval(4))
            try session.finishSet(at:now.addingTimeInterval(5))
            try session.submit(reps:3,feedback:[],notes:"核对",at:now.addingTimeInterval(6))
        }
        let record=try XCTUnwrap(LocalTrainingRepository(fileURL:url).archive.sessions.first?.records.first)
        XCTAssertEqual(record.assistedEvidence?.action,.squat)
        XCTAssertEqual(record.assistedEvidence?.automaticCount,1);XCTAssertEqual(record.reps,3)
        XCTAssertNil(record.visualEvidence);XCTAssertNil(record.rhythmAssessment);XCTAssertNil(record.formAssessment)
        XCTAssertEqual(record.assistedEvidence?.phaseStatus,"not_provided")
        var wrong=try TrainingSession(plan:plan,now:now)
        XCTAssertThrowsError(try wrong.beginCountOnly(action:.curl,side:.left,source:.fixture,at:now))
    }

    func testSquatCandidateNeedsWholeFrozenChainSoHipOnlyBackgroundCannotStealCentre() throws {
        var session=try CountOnlySession(action:.squat,side:.left,originSeconds:10,source:.cachedPose)
        var hipOnlySelection=SquatCountOnlyCounter(side:.left)
        let angles=Array(repeating:170.0,count:5)+[150,130,110,95]+Array(repeating:95.0,count:4)+[110,130,150,170]+Array(repeating:170.0,count:5)
        for (i,angle) in angles.enumerated() {
            let r=angle * .pi/180, time=10+Double(i)*0.1
            let target=BodyPose(points:[.leftHip:.init(x:0.6,y:0.8),.leftKnee:.init(x:0.6,y:0.5),
                .leftAnkle:.init(x:0.6+sin(r)*0.25*360/640,y:0.5+cos(r)*0.25)])
            let background=BodyPose(points:[.leftHip:.init(x:0.485,y:0.7)])
            let people=i%2==0 ? [background,target]:[target,background]
            try session.process(.init(timestamp:time,width:640,height:360,people:people))
            try hipOnlySelection.process(.init(timestamp:time,width:640,height:360,people:[background]))
        }
        XCTAssertEqual(hipOnlySelection.events.count,0)
        XCTAssertEqual(hipOnlySelection.lastReason,"missing_required_joint")
        XCTAssertEqual(session.evidence.observedCount,1)
        XCTAssertEqual(session.evidence.action,.squat)
    }

    func testReplayMirrorStaysUnknownAndCameraMirrorComesFromItsTransportContract() throws {
        var replay=try TrainingSession(plan:plan(),now:now)
        _=try replay.beginAssistedCurl(side:.left,source:.fixture,at:now)
        XCTAssertEqual(replay.currentAssistedEvidence?.runs.first?.pixelMirror,.unknown)
        XCTAssertEqual(replay.currentAssistedEvidence?.runs.first?.coordinateConvention,"vision-normalized-bottom-left-pixel-up-v1")
        var live=try TrainingSession(plan:plan(),now:now)
        _=try live.beginAssistedCurl(side:.left,source:.camera,at:now)
        XCTAssertEqual(live.currentAssistedEvidence?.runs.first?.pixelMirror,.knownUnmirrored)
    }

    func testFailedV3WriteThenOrdinaryV2UpdateCanRetryMigrationWithoutLosingEitherBackup() throws {
        let url=try file();var failNext=false
        let repo=try LocalTrainingRepository(fileURL:url,writer:{ data,url in
            if failNext {failNext=false;throw CocoaError(.fileWriteOutOfSpace)}
            try data.write(to:url,options:.atomic)
        })
        try repo.start(plan:plan(),at:now)
        let firstV2=try Data(contentsOf:url),id=try XCTUnwrap(repo.archive.currentSession?.id)
        failNext=true
        XCTAssertThrowsError(try repo.updateSession(id:id) {_=try $0.beginAssistedCurl(side:.left,source:.fixture,at:now)})
        XCTAssertEqual(try Data(contentsOf:url),firstV2)
        XCTAssertEqual(repo.archive.schemaVersion,2)
        try repo.update {$0.plan.focus="Ordinary v2 edit after failed v3 write"}
        let secondV2=try Data(contentsOf:url);XCTAssertNotEqual(firstV2,secondV2)
        try repo.updateSession(id:id) {_=try $0.beginAssistedCurl(side:.left,source:.fixture,at:now)}
        XCTAssertEqual(repo.archive.schemaVersion,3)
        let backups=try FileManager.default.contentsOfDirectory(at:url.deletingLastPathComponent(),includingPropertiesForKeys:nil)
            .filter {$0.lastPathComponent.hasPrefix(url.lastPathComponent+".pre-assisted-v2-") && $0.lastPathComponent.hasSuffix("-original")}
        let bytes=try backups.map {try Data(contentsOf:$0)}
        XCTAssertEqual(bytes.count,2)
        XCTAssertTrue(bytes.contains(firstV2));XCTAssertTrue(bytes.contains(secondV2))
    }

    func testContentAddressedBackupDigestMatchesIndependentKnownVectors() {
        XCTAssertEqual(TrainingArchiveDigest.sha256(Data()),"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(TrainingArchiveDigest.sha256(Data("abc".utf8)),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let multipleChunks=Data((0..<1024).map {UInt8($0%256)})
        XCTAssertEqual(TrainingArchiveDigest.sha256(multipleChunks),"785b0751fc2c53dc14a4ce3d800e69ef9ce1009eb327ccf458afe09c242c26c9")
    }

    func testSharedCameraCadencePreservesGreedyPTSAndExplicitReset() {
        var gate=PoseFrameCadenceGate()
        XCTAssertTrue(gate.accepts(10));XCTAssertFalse(gate.accepts(0))
        gate.resetSourceClock()
        XCTAssertTrue(gate.accepts(0));XCTAssertFalse(gate.accepts(1.0/15));XCTAssertTrue(gate.accepts(2.0/15))
        XCTAssertFalse(gate.accepts(.nan));XCTAssertFalse(gate.accepts(.infinity))
        XCTAssertTrue(gate.accepts(4.0/15))
    }

}
