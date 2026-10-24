import Foundation
import FoxPoseExperimentKit

#if os(macOS)
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.count == 2 && args[0] == "stream" {
        try streamFrames(URL(fileURLWithPath: args[1]))
    } else if args.count == 5 && ["evaluate", "evaluate-core"].contains(args[0]) {
        try await evaluate(URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[2]), args[3],
                           URL(fileURLWithPath: args[4]), includeAppleCounter: args[0] == "evaluate")
    } else {
        throw NSError(domain: "FoxPoseExperiment", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Usage: fox-pose-experiment stream <manifest> | evaluate[-core] <manifest> <cache> <vision|mediapipe> <new-report>"])
    }
} catch {
    FileHandle.standardError.write(Data("Experiment failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
#else
print("Use the isolated Fox Pose Lab app for device video experiments.")
exit(1)
#endif
