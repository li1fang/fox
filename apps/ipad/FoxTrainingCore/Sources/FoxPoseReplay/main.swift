import Foundation
import FoxTrainingCore

struct Archive: Decodable { let trials: [VisionTrial] }
struct Comparison: Encodable {
    let id: UUID
    let exercise: VisionExercise
    let source: VisionInputSource
    let originalCount: Int
    let replayCount: Int?
    let candidateCount: Int?
    let configuration: PoseCounterConfiguration?
    let candidateResetCounts: [String: Int]?
    let complete: Bool
    let unavailableReason: String?
    var candidateRuntimePolicy: PoseRuntimePolicy? = nil
    var candidateRepetitions: [CurlRepetition]? = nil
}

do {
    var args = Array(CommandLine.arguments.dropFirst())
    let currentRuntime = args.contains("--current-runtime")
    args.removeAll { $0 == "--current-runtime" }
    guard (1...2).contains(args.count) else {
        throw NSError(domain: "fox-pose-replay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: fox-pose-replay <report-or-archive.json> [configuration.json] [--current-runtime]"])
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[0]))
    let decoder = LocalTrainingRepository.decoder()
    let trials: [VisionTrial]
    if let archive = try? decoder.decode(Archive.self, from: data) { trials = archive.trials }
    else { trials = [try decoder.decode(VisionTrial.self, from: data)] }
    let candidate = args.count == 2 ? try PoseCounterConfiguration.decode(Data(contentsOf: URL(fileURLWithPath: args[1]))) : nil
    var comparisons: [Comparison] = []
    for trial in trials {
        try trial.validate()
        if trial.counterDiagnostics?.configuration.tracking.recordsTrace != true || trial.counterDiagnostics?.samples.isEmpty != false
            || (trial.counterDiagnostics?.droppedSamples ?? 0) > 0 {
            let reason = (trial.counterDiagnostics?.droppedSamples ?? 0) > 0 ? PoseReplayError.truncated : PoseReplayError.unavailable
            comparisons.append(Comparison(id: trial.id, exercise: trial.resolvedExercise, source: trial.source,
                originalCount: trial.automaticCount, replayCount: nil, candidateCount: nil, configuration: nil,
                candidateResetCounts: nil, complete: false, unavailableReason: reason.localizedDescription))
            continue
        }
        let original = try PoseReplay.replay(trial)
        guard original.repetitions == trial.repetitions else {
            throw NSError(domain: "fox-pose-replay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Stored configuration did not reproduce trial \(trial.id); comparison rejected."])
        }
        let alternative = try PoseReplay.replay(trial, configuration: candidate, runtimePolicy: currentRuntime ? .standard : nil)
        comparisons.append(Comparison(id: trial.id, exercise: trial.resolvedExercise, source: trial.source,
            originalCount: trial.automaticCount, replayCount: original.repetitions.count, candidateCount: alternative.repetitions.count,
            configuration: alternative.configuration, candidateResetCounts: alternative.diagnostics.resetCounts, complete: true, unavailableReason: nil,
            candidateRuntimePolicy: currentRuntime ? alternative.runtimePolicy : nil,
            candidateRepetitions: currentRuntime ? alternative.repetitions : nil))
    }
    FileHandle.standardOutput.write(try LocalTrainingRepository.encoder().encode(comparisons))
    FileHandle.standardOutput.write(Data("\n".utf8))
    if !comparisons.contains(where: \.complete) { throw PoseReplayError.unavailable }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
