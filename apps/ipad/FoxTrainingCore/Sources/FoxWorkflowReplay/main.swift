import Foundation
import FoxTrainingCore

struct Job: Decodable {
    struct Asset: Decodable {let path:String;let bytes:Int;let sha256:String}
    struct Case: Codable {let id:String;let arm:ArmSide;let startSeconds:Double;let endSeconds:Double;let formalStartSeconds:Double;let strategyID:String;let personID:String?;let bodyView:String}
    let id:String;let schema:String;let input:String;let files:[Asset];let workflow:VisionWorkflowBinding;let cases:[Case]
    let sourceClock:VisionWorkflowCache.ClockAsset
}
struct CaseResult: Encodable {let specification:Job.Case;let replay:VisionWorkflowReplayResult}
struct Result: Encodable {
    var schema="fox.vision_workflow_result.v1"
    let jobID:String
    let jobSHA256:String
    let workflow:VisionWorkflowBinding
    let inputProvenance:[String:String]
    let cases:[CaseResult]
    var inferencePerformed=false
    var execution="portable_core_replay_not_actual_app"
    var acceptance="not_assessed"
}
func safe(_ value:String)->Bool {!value.isEmpty && value.count<=100 && value != "." && value != ".." && value.allSatisfy{$0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0))}}
do {
    guard CommandLine.arguments.count==3 else {throw NSError(domain:"workflow",code:1,userInfo:[NSLocalizedDescriptionKey:"fox-workflow-replay <job-folder> <fresh-output.json>"])}
    let folder=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath:output.path) else {throw TrainingError.invalidRecord}
    let bytes=try Data(contentsOf:folder.appendingPathComponent("job.json"))
    guard bytes.count<=131072 else {throw TrainingError.invalidRecord}
    let job=try JSONDecoder().decode(Job.self,from:bytes)
    try job.workflow.validate()
    guard job.schema=="fox.vision_batch_job.v1",UUID(uuidString:job.id) != nil,safe(job.input),
          (1...4).contains(job.files.count),Set(job.files.map(\.path)).count==job.files.count,
          job.files.contains(where:{$0.path==job.input}), (1...16).contains(job.cases.count),
          Set(job.cases.map(\.id)).count==job.cases.count else {throw TrainingError.invalidRecord}
    for f in job.files {
        guard safe(f.path),f.bytes>0,f.bytes<=512*1024*1024 else {throw TrainingError.invalidRecord}
        let url=folder.appendingPathComponent(f.path),info=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
        guard info.isSymbolicLink != true,info.isRegularFile==true else {throw TrainingError.invalidRecord}
        let data=try Data(contentsOf:url)
        guard data.count==f.bytes,VisionWorkflowDigest.sha256(data)==f.sha256 else {throw TrainingError.invalidRecord}
    }
    let raw=try Data(contentsOf:folder.appendingPathComponent(job.input))
    guard raw.count<=64*1024*1024,let text=String(data:raw,encoding:.utf8) else {throw TrainingError.invalidRecord}
    let lines=text.split(whereSeparator:\.isNewline)
    guard (3...20001).contains(lines.count) else {throw TrainingError.invalidRecord}
    let header=try JSONDecoder().decode([String:String].self,from:Data(lines[0].utf8))
    try VisionWorkflowCache.validateHeader(header)
    let frames=try lines.dropFirst().map{try JSONDecoder().decode(PoseVideoRow.self,from:Data($0.utf8)).frame()}
    guard job.sourceClock.timebase=="original_cmtime_jsonl",job.sourceClock.role=="observer_input",job.files.contains(where:{$0.path==job.sourceClock.path}) else {throw TrainingError.invalidRecord}
    try VisionWorkflowCache.validateClock(Data(contentsOf:folder.appendingPathComponent(job.sourceClock.path)),frames:frames)
    guard zip(frames,frames.dropFirst()).allSatisfy({$0.timestamp<$1.timestamp}),frames.last!.timestamp-frames.first!.timestamp<=600.1 else {throw TrainingError.invalidRecord}
    let results=try job.cases.map {c->CaseResult in
        guard safe(c.id),c.startSeconds>=0,c.endSeconds.isFinite,c.endSeconds>c.formalStartSeconds,
              c.endSeconds-c.startSeconds<=600,c.formalStartSeconds==c.startSeconds+2,c.strategyID==job.workflow.strategyID,
              c.bodyView==job.workflow.bodyView else {throw TrainingError.invalidRecord}
        let selected=frames.filter{$0.timestamp>=c.startSeconds && $0.timestamp<c.endSeconds}
        guard selected.first?.timestamp==c.startSeconds else {throw TrainingError.invalidRecord}
        return .init(specification:c,replay:try VisionWorkflowReplay.run(action:job.workflow.action,side:c.arm,frames:selected))
    }
    let result=Result(jobID:job.id,jobSHA256:VisionWorkflowDigest.sha256(bytes),workflow:job.workflow,inputProvenance:header,cases:results)
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
    // Exclusive creation protects a prior result even if it appears after the initial check.
    try encoder.encode(result).write(to:output,options:.withoutOverwriting)
    print("{\"status\":\"completed\",\"execution\":\"portable_core_replay_not_actual_app\"}")
} catch {fputs("workflow replay failed: \(error)\n",stderr);exit(1)}
