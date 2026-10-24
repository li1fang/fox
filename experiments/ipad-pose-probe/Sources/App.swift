import UIKit
import FoxPoseExperimentKit

private final class RunActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    func set(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
    func check() throws {
        lock.lock(); let value = active; lock.unlock()
        if !value { throw NSError(domain: "FoxPoseLab", code: 2, userInfo: [NSLocalizedDescriptionKey: "App left foreground; run rejected"]) }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let label = UILabel()
    private let activity = RunActivity()
    private var started = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        label.text = "Fox Pose Lab\nReady"
        label.font = .monospacedSystemFont(ofSize: 24, weight: .medium)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)
        ])
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            for name in ["Input", "Runs"] {
                try FileManager.default.createDirectory(at: documents.appendingPathComponent(name), withIntermediateDirectories: true)
            }
        } catch { label.text = error.localizedDescription }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        activity.set(true)
        guard !started, let runID = ProcessInfo.processInfo.environment["FOX_POSE_RUN_ID"],
              !runID.isEmpty, runID.count < 80,
              runID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return }
        started = true; application.isIdleTimerDisabled = true
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let run = documents.appendingPathComponent("Runs").appendingPathComponent(runID)
        guard !FileManager.default.fileExists(atPath: run.path) else {
            label.text = "Fox Pose Lab\nRun already exists\n\(runID)"
            application.isIdleTimerDisabled = false
            return
        }
        let manifest = documents.appendingPathComponent("Input/manifest.json")
        let activity = self.activity
        let began = ProcessInfo.processInfo.systemUptime
        let update: @Sendable (String, Int, String?) throws -> Void = { [weak self] phase, frames, error in
            let status: [String: Any] = ["schema": "fox.ipad_pose_probe_status.v1", "runID": runID,
                "phase": phase, "sampleIndex": frames, "error": error as Any? ?? NSNull(),
                "source": "device-video-not-camera", "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began,
                "recordedAt": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]).write(to: run.appendingPathComponent("status.json"), options: .atomic)
            DispatchQueue.main.async {
                self?.label.text = "Fox Pose Lab\n\(phase)\n\(frames) / 2004\n\(error ?? "")"
            }
        }
        Task.detached {
            do {
                guard !FileManager.default.fileExists(atPath: run.path) else {
                    throw NSError(domain: "FoxPoseLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Run already exists; choose a new run ID"])
                }
                try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
                try activity.check(); try update("extracting", 0, nil)
                let partial = run.appendingPathComponent("vision.partial.jsonl")
                try exportVisionCache(manifest, output: partial) { index in
                    try activity.check(); try update("extracting", index, nil)
                }
                try activity.check()
                let cache = run.appendingPathComponent("vision.jsonl")
                try FileManager.default.moveItem(at: partial, to: cache)
                try update("evaluating", 2004, nil)
                try await evaluate(manifest, cache, "vision", run.appendingPathComponent("evaluation.json"), includeAppleCounter: false)
                try activity.check(); try update("completed", 2004, nil)
            } catch {
                // A partial cache is never accepted as a completed device experiment.
                if FileManager.default.fileExists(atPath: run.path) {
                    try? update("failed", 0, error.localizedDescription)
                }
                DispatchQueue.main.async { [weak self] in self?.label.text = "Fox Pose Lab\nFailed\n\(error.localizedDescription)" }
            }
            await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    func applicationWillResignActive(_ application: UIApplication) { activity.set(false) }
}
