import Foundation
import FoxTrainingCore
import XCTest
@testable import Fox

@MainActor
final class CountOnlyReplayBatchTests: XCTestCase {
    func attachWorkflow(_ action:String,documents:URL,id:UUID) throws {
        let folder=documents.appendingPathComponent("FoxReplay/Jobs/\(id.uuidString)"),raw=folder.appendingPathComponent("public.jsonl")
        if action=="curl" {
            let original=try String(contentsOf:raw,encoding:.utf8).split(separator:"\n").first!
            var bytes=Data(original.utf8);bytes.append(10)
            let segments:[[Double]]=[Array(repeating:170.0,count:65),[160,150,140,130,120,110,100,90,80,70,60,50,40],
                Array(repeating:40.0,count:12),[50,60,70,80,90,100,110,120,130,140,150,160,170],Array(repeating:170.0,count:15)]
            let angles=segments.flatMap{$0}
            for (i,a) in angles.enumerated() {
                let r=a * .pi/180
                let p:[PoseTraceJoint]=[.init(joint:.rightShoulder,x:0.5,y:0.7,confidence:1),.init(joint:.rightElbow,x:0.5,y:0.5,confidence:1),
                    .init(joint:.rightWrist,x:0.5+sin(r)*0.2*360/640,y:0.5+cos(r)*0.2,confidence:1),.init(joint:.rightHip,x:0.5,y:0.3,confidence:1)]
                bytes.append(try JSONEncoder().encode(PoseVideoRow(seconds:Double(i)/15,width:640,height:360,people:[p])));bytes.append(10)
            }
            try bytes.write(to:raw)
        }
        let lines=try String(contentsOf:raw,encoding:.utf8).split(separator:"\n").dropFirst()
        let clock=folder.appendingPathComponent("times.jsonl")
        let clockText=lines.enumerated().map{i,_ in "{\"value\":\"\(i)\",\"timescale\":15,\"epoch\":\"0\"}"}.joined(separator:"\n")+"\n"
        try Data(clockText.utf8).write(to:clock)
        var job=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("job.json"))) as! [String:Any]
        let binding=try VisionWorkflowBinding.load(action)
        job["workflow"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(binding))
        job["sourceClock"]=["path":"times.jsonl","timebase":"original_cmtime_jsonl","role":"observer_input"]
        job["mode"]=binding.consumerMode
        job["files"]=try [raw,clock].map {url->[String:Any] in let a=try VisionDiagnosticArchive.asset(url);return ["path":a.path,"bytes":a.bytes,"sha256":a.sha256]}
        var c=(job["cases"] as! [[String:Any]])[0]
        c.removeValue(forKey:"countOnlyAction");c.removeValue(forKey:"exercise")
        c[action=="squat" ? "countOnlyAction":"exercise"]=action
        c["strategyID"]=binding.strategyID;c["formalStartSeconds"]=2;c["bodyView"]="side";c["personID"]="public-synthetic-person"
        c["endSeconds"]=Double(lines.count)/15;job["cases"]=[c]
        try JSONSerialization.data(withJSONObject:job,options:.sortedKeys).write(to:folder.appendingPathComponent("job.json"))
    }
    func testWorkflowSquatBindingPreservesFixedPreludeAndExplicitSkippedFrameFacts() async throws {
        let (documents,id)=try fixture();try attachWorkflow("squat",documents:documents,id:id)
        let result=try await VisionReplayBatch.run(id:id,documents:documents,countOnlyDiagnosticEnabled:true)
        XCTAssertEqual(result.workflow?.algorithm,CountOnlyAction.squat.algorithm)
        let c=try XCTUnwrap(result.countOnlyCases?.first)
        XCTAssertEqual(c.automaticCount,1);XCTAssertEqual(c.formalStartSeconds,2)
        XCTAssertTrue(c.trace.contains{!$0.admitted})
        XCTAssertTrue(c.trace.filter{!$0.admitted}.allSatisfy{$0.reason=="cadence_not_admitted"})
        XCTAssertNil(c.record.reps);XCTAssertNil(c.record.visualEvidence)
        XCTAssertEqual(c.phaseStatus,"not_provided")
    }
    func testWorkflowOriginalCurlUsesActualStoreAndNeverEnablesFrontalCountOnly() async throws {
        let (documents,id)=try fixture();try attachWorkflow("curl",documents:documents,id:id)
        let result=try await VisionReplayBatch.run(id:id,documents:documents,countOnlyDiagnosticEnabled:true)
        XCTAssertEqual(result.workflow?.algorithm,try MotionStrategy.load(.curl).algorithm)
        XCTAssertNil(result.countOnlyCases)
        let c=try XCTUnwrap(result.cases.first),record=try XCTUnwrap(c.record)
        XCTAssertEqual(c.repetitions.count,1)
        XCTAssertEqual(record.visualEvidence?.repetitions,c.repetitions)
        XCTAssertNil(record.assistedEvidence);XCTAssertNil(record.reps);XCTAssertNil(record.sideRepetitions)
        XCTAssertNotNil(c.repetitions.first?.lowerSeconds)
        XCTAssertEqual(c.archiveAssets?.count,1)
        XCTAssertTrue(c.workflowTrace?.filter{!$0.admitted}.allSatisfy{$0.reason=="cadence_not_admitted"} == true)
    }
    func testWorkflowWrongStrategyOrDetachedOriginalClockFailsBeforeProducingRecord() async throws {
        for invalid in ["binding","clock"] {
            let (documents,id)=try fixture();try attachWorkflow("squat",documents:documents,id:id)
            let folder=documents.appendingPathComponent("FoxReplay/Jobs/\(id.uuidString)"),file=folder.appendingPathComponent("job.json")
            var job=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
            if invalid=="binding" {var w=job["workflow"] as! [String:Any];w["algorithm"]="central-continuous-curl-v1";job["workflow"]=w}
            else {
                let clock=folder.appendingPathComponent("times.jsonl");try Data("{\"value\":\"0\",\"timescale\":15,\"epoch\":\"0\"}\n".utf8).write(to:clock)
                var assets=job["files"] as! [[String:Any]];let a=try VisionDiagnosticArchive.asset(clock)
                assets[1]=["path":a.path,"bytes":a.bytes,"sha256":a.sha256];job["files"]=assets
            }
            try JSONSerialization.data(withJSONObject:job).write(to:file)
            do {_=try await VisionReplayBatch.run(id:id,documents:documents,countOnlyDiagnosticEnabled:true);XCTFail("Invalid workflow accepted")}
            catch {XCTAssertFalse(error is CancellationError)}
            XCTAssertFalse(FileManager.default.fileExists(atPath:documents.appendingPathComponent("FoxReplayRuns/\(id.uuidString)/public-squat.training.json").path))
        }
    }
    func fixture() throws -> (URL,UUID) {
        let documents=FileManager.default.temporaryDirectory.appendingPathComponent("PublicCountOnly-\(UUID())")
        let id=UUID(),input=documents.appendingPathComponent("FoxReplay/Jobs/\(id.uuidString)")
        try FileManager.default.createDirectory(at:input,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:documents)}
        let prelude=Array(repeating:170.0,count:5)+[140,100]+Array(repeating:95.0,count:5)+[130,170]+Array(repeating:170.0,count:16)
        let formal=Array(repeating:170.0,count:8)+[150,130,110,95]+Array(repeating:95.0,count:8)+[110,130,150,170]+Array(repeating:170.0,count:8)
        let angles=prelude+formal
        let header=["schema":"fox.count_only_pose_input.v1","inputClass":"public_synthetic","source":"synthetic_fixture",
            "sourceSHA256":String(repeating:"0",count:64),"visionRevision":"1","timebase":"source_pts_seconds",
            "coordinateConvention":"vision-normalized-bottom-left-pixel-up-v1","pixelMirror":"unknown"]
        var bytes=try JSONEncoder().encode(header);bytes.append(10)
        for (i,angle) in angles.enumerated() {
            let r=angle * .pi/180
            let joints=[PoseTraceJoint(joint:.rightHip,x:0.6,y:0.8,confidence:1),
                PoseTraceJoint(joint:.rightKnee,x:0.6,y:0.5,confidence:1),
                PoseTraceJoint(joint:.rightAnkle,x:0.6+sin(r)*0.25*360/640,y:0.5+cos(r)*0.25,confidence:1)]
            let row=PoseVideoRow(seconds:Double(i)/15,width:640,height:360,people:[joints])
            bytes.append(try JSONEncoder().encode(row));bytes.append(10)
        }
        let raw=input.appendingPathComponent("public.jsonl");try bytes.write(to:raw)
        let asset=try VisionDiagnosticArchive.asset(raw)
        let job:[String:Any]=["schema":"fox.vision_batch_job.v1","id":id.uuidString,"kind":"cache","mode":"countOnly","input":"public.jsonl",
            "files":[["path":asset.path,"bytes":asset.bytes,"sha256":asset.sha256]],
            "cases":[["id":"public-squat","countOnlyAction":"squat","arm":"right","startSeconds":0,"endSeconds":Double(angles.count)/15,"rebindAtSeconds":[]]]]
        try JSONSerialization.data(withJSONObject:job,options:[.sortedKeys]).write(to:input.appendingPathComponent("job.json"))
        return(documents,id)
    }
    func testPublicCountOnlyDiagnosticUsesActualConsumerCadencePreludeAndUnknownManualRecord() async throws {
        let (documents,id)=try fixture()
        let result=try await VisionReplayBatch.run(id:id,documents:documents,countOnlyDiagnosticEnabled:true)
        let output=documents.appendingPathComponent("FoxReplayRuns/\(id.uuidString)")
        let json=try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("result.json"))) as! [String:Any]
        XCTAssertEqual(json["mode"] as? String,"countOnly")
        XCTAssertFalse(result.inferencePerformed)
        let cases=try XCTUnwrap(json["countOnlyCases"] as? [[String:Any]])
        let item=try XCTUnwrap(cases.first)
        XCTAssertEqual(item["automaticCount"] as? Int,1,"The complete prelude cycle must not count")
        XCTAssertEqual(item["formalStartSeconds"] as? Double,2)
        let pts=try XCTUnwrap(item["admittedFramePTSSeconds"] as? [Double])
        XCTAssertEqual(pts.prefix(3),[0,2.0/15,4.0/15])
        let record=try XCTUnwrap(item["record"] as? [String:Any])
        let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("public-squat.training.json"))) as! [String:Any]
        let savedSessions=try XCTUnwrap(saved["sessions"] as? [[String:Any]])
        let savedRecords=savedSessions.flatMap {$0["records"] as? [[String:Any]] ?? []}
        let actual=try XCTUnwrap(savedRecords.first {$0["id"] as? String == record["id"] as? String})
        XCTAssertEqual(record as NSDictionary,actual as NSDictionary,"Diagnostic JSON must preserve the actual saved record, including wall-clock milliseconds")
        XCTAssertNil(record["reps"]);XCTAssertNil(record["sideRepetitions"])
        XCTAssertEqual(record["countingMethod"] as? String,"unconfirmed")
        XCTAssertNil(record["visualEvidence"]);XCTAssertNil(record["rhythmAssessment"])
        let events=try XCTUnwrap(item["events"] as? [[String:Any]])
        XCTAssertEqual(events.count,1)
        let evidence=try XCTUnwrap(record["assistedEvidence"] as? [String:Any])
        let runs=try XCTUnwrap(evidence["runs"] as? [[String:Any]])
        let run=try XCTUnwrap(runs.first)
        XCTAssertEqual(run["pixelMirror"] as? String,"unknown")
        let facts=try XCTUnwrap(run["evidence"] as? [String:Any])
        XCTAssertEqual(facts["inputOriginSeconds"] as? Double,0)
        XCTAssertEqual(facts["formalStartSeconds"] as? Double,2)
        XCTAssertEqual(facts["phaseStatus"] as? String,"not_provided")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(events.first?["completedAtSourcePTSSeconds"] as? Double),2)
        XCTAssertTrue(FileManager.default.fileExists(atPath:documents.appendingPathComponent("FoxReplayRuns/\(id.uuidString)/public-squat.training.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:documents.appendingPathComponent("Fox/training-records.v1.json").path))
    }
    func testDiagnosticRejectsUnadmittedPrivateOrNonMonotonicInputsAndCannotOverwriteRun() async throws {
        for invalid in ["unadmitted","private","clock"] {
            let (documents,id)=try fixture()
            let input=documents.appendingPathComponent("FoxReplay/Jobs/\(id.uuidString)")
            if invalid != "unadmitted" {
                let raw=input.appendingPathComponent("public.jsonl")
                var lines=try String(contentsOf:raw,encoding:.utf8).split(separator:"\n").map(String.init)
                if invalid == "private" {
                    var header=try JSONDecoder().decode([String:String].self,from:Data(lines[0].utf8))
                    header["inputClass"]="private"
                    lines[0]=String(decoding:try JSONEncoder().encode(header),as:UTF8.self)
                } else { lines[2]=lines[1] }
                try Data((lines.joined(separator:"\n")+"\n").utf8).write(to:raw)
                var job=try JSONDecoder().decode(VisionBatchJob.self,from:Data(contentsOf:input.appendingPathComponent("job.json")))
                job.files=[try VisionDiagnosticArchive.asset(raw)]
                try JSONEncoder().encode(job).write(to:input.appendingPathComponent("job.json"))
            }
            do { _=try await VisionReplayBatch.run(id:id,documents:documents,countOnlyDiagnosticEnabled:invalid != "unadmitted");XCTFail("Invalid diagnostic must fail: \(invalid)") }
            catch { XCTAssertFalse(error is CancellationError) }
            let output=documents.appendingPathComponent("FoxReplayRuns/\(id.uuidString)")
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.appendingPathComponent("public-squat.training.json").path))
            let before=try Data(contentsOf:output.appendingPathComponent("status.json"))
            do {_=try await VisionReplayBatch.run(id:id,documents:documents,countOnlyDiagnosticEnabled:true);XCTFail("A consumed runID cannot be reused")}
            catch {XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("status.json")),before)}
        }
    }

}
