#if DEBUG
import Foundation
import FoxTrainingCore

/// Uses the original App coordinator/store. It never enables the experimental frontal curl.
@MainActor
enum WorkflowReplayConsumer {
    static func runLegacy(_ item:VisionBatchJob.Case,frames:[PoseFrame],output:URL,control:VisionBatchControl,
                          progress:(Int)throws->Void) async throws -> VisionBatchCaseResult {
        guard item.exercise == .curl,item.countOnlyAction == nil,let first=frames.first,
              first.timestamp==item.startSeconds,item.formalStartSeconds==first.timestamp+2,
              item.strategyID==(try VisionActionBinding.load("curl")).strategyID else {throw VisionDiagnosticArchive.error("Unsupported legacy workflow binding")}
        let archive=output.appendingPathComponent("\(item.id).training.json")
        guard !FileManager.default.fileExists(atPath:archive.path) else {throw VisionDiagnosticArchive.error("Workflow archive exists")}
        let store=TrainingStore(archiveURL:archive,diagnosticRoot:output.appendingPathComponent("work/\(item.id)/diagnostics"),
            preferences:nil,assistedDevelopmentEnabled:false)
        let controller=store.workoutVision.controller,clock=VisionReplayClock()
        controller.enableReplay(clock:clock)
        guard store.preparePractice(.curl,arm:item.arm,requestID:UUID()),let sessionID=store.session?.id else {throw VisionDiagnosticArchive.error(store.errorMessage ?? "Legacy preparation failed")}
        clock.uptime=1000
        // Arm the unchanged original preparation at source origin. Readiness may
        // occur after formal+2; it does not remove that first reference cycle.
        store.workoutVision.prepare(arm:item.arm)
        defer {store.workoutVision.stop()}
        var origin:Double?,trace:[VisionBatchTrace]=[],workflowTrace:[VisionWorkflowTrace]=[]
        for (i,frame) in frames.enumerated() {
            if i%20 == 0 {try control.check();try Task.checkCancellation();await Task.yield()}
            clock.uptime=1000+frame.timestamp-first.timestamp
            let admitted=controller.camera.admitPosePTS(frame.timestamp)
            if admitted {controller.replayFrame(.init(frame:frame,latencyMs:0,revision:1))}
            if controller.isCounting && origin == nil {origin=frame.timestamp}
            let state:String
            switch controller.startState {case .idle:state="idle";case .waiting:state="waiting";case .countdown(let n):state="countdown-\(n)";case .ready:state="ready"}
            trace.append(.init(seconds:frame.timestamp,subjectState:controller.subjectSelection.state,selectedIndex:controller.subjectSelection.index,
                startState:state,counting:controller.isCounting,automaticCount:controller.automaticCount,phase:controller.snapshot.phase))
            let reason = !admitted ? "cadence_not_admitted" : controller.isCounting
                ? controller.snapshot.failureReason?.rawValue ?? (controller.snapshot.quality == .valid ? "observed":controller.snapshot.quality.rawValue)
                : "preparing_\(controller.subjectSelection.state.rawValue)"
            workflowTrace.append(.init(sourcePTSSeconds:frame.timestamp,admitted:admitted,formal:frame.timestamp>=first.timestamp+2,
                selectedIndex:controller.subjectSelection.index,reason:reason,automaticCount:controller.automaticCount,
                reset:controller.snapshot.failureReason == .explicitInterrupt,resetReason:controller.snapshot.failureReason == .explicitInterrupt ? "explicitInterrupt":nil))
            try progress(i+1)
        }
        guard store.workoutVision.flush(),store.session?.stage == .active else {throw VisionDiagnosticArchive.error(store.errorMessage ?? "Legacy source never started; no manual record invented")}
        let reps=controller.repetitions,resets=controller.diagnostics.resetCounts
        store.workoutVision.finish()
        guard store.session?.stage == .feedback,store.updateSession({try $0.endEarly(at:clock.date)}),
              store.confirmSummary(note:"Public cache wiring; manual count remains unknown") else {throw VisionDiagnosticArchive.error(store.errorMessage ?? "Legacy record failed")}
        let reopened=TrainingStore(archiveURL:archive,preferences:nil,assistedDevelopmentEnabled:false)
        guard let saved=reopened.archive.sessions.first(where:{$0.id==sessionID}),saved.isFinished,let record=saved.records.first,
              record.assistedEvidence == nil,record.reps == nil,record.sideRepetitions == nil,
              record.visualEvidence?.repetitions==reps else {throw VisionDiagnosticArchive.error("Legacy saved facts changed")}
        return .init(specification:item,originSeconds:origin,repetitions:reps,resetCounts:resets,trace:trace,
            workflowTrace:workflowTrace,record:record,archiveAssets:[try VisionDiagnosticArchive.asset(archive)])
    }
}
#endif
