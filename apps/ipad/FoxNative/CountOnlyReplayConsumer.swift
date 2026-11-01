#if DEBUG
import Foundation
import FoxTrainingCore

struct CountOnlyBatchEvent: Codable {
    let completedAtSourcePTSSeconds: Double
    let observationRunID: UUID
    let segmentID: Int
}
struct CountOnlyBatchTrace: Codable {
    let sourcePTSSeconds: Double
    let admitted: Bool
    let formal: Bool
    let automaticCount: Int
    let reason: String
}
struct CountOnlyBatchCaseResult: Codable {
    let specification: VisionBatchJob.Case
    let sourceOriginSeconds: Double
    let formalStartSeconds: Double
    let admittedFramePTSSeconds: [Double]
    let automaticCount: Int
    let events: [CountOnlyBatchEvent]
    let record: LocalSetRecord
    let trace: [CountOnlyBatchTrace]
    let archiveAssets: [VisionDiagnosticManifest.Asset]
    var manualConfirmation = "unknown"
    var phaseStatus = "not_provided"
    var sourceTimebase = "original_source_pts_seconds_double_not_complete_cmtime"
    var eventTimeMeaning = "count_confirmation_not_anatomical_return_endpoint"
}

/// Diagnostic-only adapter. Uses the same store/coordinator/admission path, with an isolated archive.
@MainActor
enum CountOnlyReplayConsumer {
    static func run(_ item: VisionBatchJob.Case, frames: [PoseFrame], revision: Int, output: URL,
                    control: VisionBatchControl, progress: (Int) throws -> Void) async throws -> CountOnlyBatchCaseResult {
        guard let action=item.countOnlyAction, let first=frames.first, let last=frames.last,
              abs(first.timestamp-item.startSeconds)<1e-9, last.timestamp>=first.timestamp+2,
              item.rebindAtSeconds.isEmpty else {throw VisionDiagnosticArchive.error("Count-only source needs its fixed origin, 2s prelude and formal frames")}
        let formal=first.timestamp+2
        let archive=output.appendingPathComponent("\(item.id).training.json")
        guard !FileManager.default.fileExists(atPath:archive.path) else {throw VisionDiagnosticArchive.error("Diagnostic archive already exists")}
        let store=TrainingStore(archiveURL:archive,diagnosticRoot:output.appendingPathComponent("work/\(item.id)/diagnostics"),
            preferences:nil,assistedDevelopmentEnabled:true)
        let controller=store.workoutVision.controller
        let clock=VisionReplayClock()
        controller.enableReplay(clock:clock)
        if action == .squat {
            guard store.prepareSquatPractice(side:item.arm,requestID:UUID()) else {throw VisionDiagnosticArchive.error(store.errorMessage ?? "Could not prepare squat")}
        } else {
            guard store.preparePractice(.curl,arm:item.arm,requestID:UUID()) else {throw VisionDiagnosticArchive.error(store.errorMessage ?? "Could not prepare curl")}
            store.setAssistedCurlEnabled(true)
        }
        guard let sessionID=store.session?.id else {throw VisionDiagnosticArchive.error("No diagnostic session")}
        store.workoutVision.preview()
        defer {store.workoutVision.stop()}
        var started=false, admitted: [Double]=[], trace: [CountOnlyBatchTrace]=[]
        for (index,frame) in frames.enumerated() {
            if index%20 == 0 {try control.check();try Task.checkCancellation();await Task.yield()}
            if !started, frame.timestamp>=formal {
                // The fixed source boundary is independent of cadence/readiness or output counts.
                clock.uptime=1002
                store.workoutVision.prepare(arm:item.arm,sourceWindow:(origin:first.timestamp,formal:formal))
                guard store.session?.stage == .active else {throw VisionDiagnosticArchive.error(store.errorMessage ?? "Formal start failed")}
                started=true
            }
            clock.uptime=1000+frame.timestamp-first.timestamp
            let accepted=controller.camera.admitPosePTS(frame.timestamp)
            if accepted {
                admitted.append(frame.timestamp)
                controller.replayFrame(.init(frame:frame,latencyMs:0,revision:revision))
            }
            trace.append(.init(sourcePTSSeconds:frame.timestamp,admitted:accepted,formal:frame.timestamp>=formal,
                automaticCount:store.session?.observedAutomaticCount ?? 0,reason:started ? controller.assistedReason:"preview_only"))
            try progress(index+1)
        }
        guard started, store.workoutVision.flush() else {throw VisionDiagnosticArchive.error(store.errorMessage ?? "Count-only snapshot not saved")}
        store.workoutVision.finish()
        guard store.session?.stage == .feedback,
              store.updateSession({try $0.endEarly(at:clock.date)}),
              store.confirmSummary(note:"Public input diagnostic; actual manual count remains unknown") else {
            throw VisionDiagnosticArchive.error(store.errorMessage ?? "Count-only record not saved")
        }
        let reopened=TrainingStore(archiveURL:archive,preferences:nil,assistedDevelopmentEnabled:true)
        guard let saved=reopened.archive.sessions.first(where:{$0.id == sessionID}), saved.isFinished,
              let record=saved.records.first, let evidence=record.assistedEvidence,
              evidence.action == action, evidence.side == item.arm, record.reps == nil, record.sideRepetitions == nil,
              record.countingMethod == "unconfirmed", record.visualEvidence == nil,
              record.rhythmAssessment == nil, record.formAssessment == nil else {
            throw VisionDiagnosticArchive.error("Saved count-only facts/unknown confirmation changed")
        }
        let events=evidence.runs.flatMap { run in
            run.evidence?.events.map { event in
                CountOnlyBatchEvent(completedAtSourcePTSSeconds:run.evidence!.inputOriginSeconds+event.completedAtSeconds,
                    observationRunID:run.id,segmentID:event.segmentID)
            } ?? []
        }
        let files=try FileManager.default.contentsOfDirectory(at:output,includingPropertiesForKeys:nil)
            .filter {$0.lastPathComponent == archive.lastPathComponent || $0.lastPathComponent.hasPrefix(archive.lastPathComponent+".")}
            .sorted {$0.lastPathComponent<$1.lastPathComponent}
        return .init(specification:item,sourceOriginSeconds:first.timestamp,formalStartSeconds:formal,
            admittedFramePTSSeconds:admitted,automaticCount:evidence.automaticCount,events:events,record:record,trace:trace,
            archiveAssets:try files.map {try VisionDiagnosticArchive.asset($0)})
    }
}
#endif
