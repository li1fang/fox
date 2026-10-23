#if DEBUG
import SwiftUI

struct VisionReplayBatchView: View {
    let id: UUID
    @State private var control = VisionBatchControl()
    @State private var started = false
    @State private var finished = false
    @State private var phase = "待运行"
    @State private var frames = 0
    @State private var error: String?
    @State private var result: VisionBatchResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("视觉回放").font(.title2.bold())
            Text(phase).font(.headline).accessibilityIdentifier("batch-status")
            Text("\(frames) 帧").monospacedDigit().accessibilityIdentifier("batch-frames")
            if !finished { ProgressView() }
            if let result {
                if result.mode == .observations { Text("姿态观测已导出").accessibilityIdentifier("batch-observations-complete") }
                ForEach(result.cases, id: \.specification.id) { item in
                    LabeledContent(item.specification.id, value: "\(item.repetitions.count) 次")
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !finished {
                Button { control.stop("userCancelled") } label: { Label("取消", systemImage: "xmark.circle") }
                    .buttonStyle(.bordered).accessibilityIdentifier("batch-cancel")
            }
        }.padding(24).frame(maxWidth: 620, maxHeight: .infinity, alignment: .center)
        .task { recordLifecycle("appeared"); startIfActive() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            recordLifecycle("becameActive")
            startIfActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if started && !finished { control.stop("backgrounded") }
        }
        .onDisappear { if !finished { control.stop("viewClosed") } }
    }
    private func recordLifecycle(_ event: String) {
        let state = UIApplication.shared.applicationState.rawValue
        print("Fox batch lifecycle: \(event), applicationState=\(state)")
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FoxReplayLaunches")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bytes = try JSONSerialization.data(withJSONObject: ["jobID": id.uuidString,
                "event": event, "applicationState": state, "time": Date().timeIntervalSince1970])
            try bytes.write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        } catch { print("Fox batch lifecycle receipt failed: \(error.localizedDescription)") }
    }
    private func startIfActive() {
        guard !started, UIApplication.shared.applicationState == .active else { return }
        started = true
        Task { @MainActor in
            let previousIdle = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = previousIdle; finished = true }
            do {
                result = try await VisionReplayBatch.run(id: id,
                    documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], control: control) { value, count in
                        guard !finished else { return }
                        phase = ["validating":"校验输入", "extracting":"识别录像", "replaying":"回放控制流程", "observing":"整理姿态观测",
                                 "completed":"已完成", "cancelled":"已取消", "failed":"失败"][value] ?? value
                        frames = count
                    }
            } catch { self.error = error.localizedDescription; phase = error is VisionBatchCancelled ? "已取消" : "失败" }
        }
    }
}
#endif
