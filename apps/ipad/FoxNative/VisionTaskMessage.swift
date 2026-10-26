import FoxTrainingCore
import SwiftUI

// Presentation only: never advances tracking, creates a repetition, or estimates a phase.
struct VisionTaskMessage {
    let detail: String
    let allowsPlannedTempo: Bool

    init(start: PoseStartState, subject: PoseSubjectState, tracking: PoseTrackingState,
         counting: Bool, hasTrial: Bool, count: Int) {
        allowsPlannedTempo = !start.isPreparing && counting && subject == .bound && tracking == .tracking
        let retained = count > 0 ? "已记 \(count) 次保留 · " : ""
        if start.isPreparing {
            if case .countdown = start { detail = retained + "已就位，倒计时后开始" }
            else if subject == .ambiguous { detail = retained + "请保留一位训练者入镜，等待锁定" }
            else { detail = retained + "露出所选侧肩肘，稳定后自动开始" }
        } else if counting {
            if subject == .lost { detail = "已记 \(count) 次保留 · 重新就位后继续，或结束核对" }
            else if subject == .occluded || tracking == .grace { detail = "已记 \(count) 次保留 · 暂时看不清，等待恢复" }
            else if subject == .ambiguous { detail = retained + "主体不明确，请保持一位训练者入镜" }
            else if tracking == .lost { detail = retained + "关节看不清，回到起点后继续" }
            else { detail = "自动 \(count) 次 · 结束后核对" }
        } else if hasTrial {
            detail = "已记 \(count) 次保留 · 就位后继续，或结束核对"
        } else { detail = "准备好后开始，再走回机位" }
    }
}

enum VisionReportInput {
    static func validReference(_ text: String) -> Bool {
        text.isEmpty || Int(text).map { (0...10000).contains($0) } == true
    }
}

extension VisionLabController {
    func taskMessage(automaticCount: Int? = nil) -> VisionTaskMessage {
        VisionTaskMessage(start: startState, subject: subjectSelection.state, tracking: snapshot.trackingState,
            counting: isCounting, hasTrial: trialActive, count: automaticCount ?? self.automaticCount)
    }

    var savedReceipt: String? {
        guard !trialActive, !isPreparing, let report = lastTrial else { return nil }
        return "记录已保存 · 自动 \(report.automaticCount) · 确认 \(report.confirmedCount)" +
            (report.referenceCount.map { " · 人工参考 \($0)" } ?? " · 人工参考未填写")
    }
}

struct VisionTaskDetail: View {
    let message: VisionTaskMessage
    var identifier = "vision-task-detail"
    var body: some View {
        Text(message.detail).font(.callout.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}
