import SwiftUI

@main
struct FoxApp: App {
    init() {
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["FOX_POSE_BATCH_JOB"] {
            print("Fox batch launch requested: \(id)")
        }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["FOX_POSE_BATCH_JOB"], let id = UUID(uuidString: raw) {
                VisionReplayBatchView(id: id)
            } else { normalRoot }
            #else
            normalRoot
            #endif
        }
    }
    @ViewBuilder private var normalRoot: some View {
            if let scenario = DesignScenario.active {
                #if DEBUG
                DesignScenarioHost(scenario: scenario)
                #endif
            } else if ProcessInfo.processInfo.environment["FOX_START_SCREEN"] == "vision" ||
                ProcessInfo.processInfo.environment["FOX_START_SCREEN"] == "training" ||
                ProcessInfo.processInfo.environment["FOX_PREPARE_DAY1_DRAFT"] == "1" {
                FoxRootView()
            } else {
                FoxHomeView()
            }
    }
}
