import FoxTrainingCore
import SwiftUI

struct TrialReviewFields: View {
    @Binding var information: String
    @Binding var softwareIssue: String
    @Binding var trainingFeeling: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("本次反馈（可选）").font(.headline)
            field("信息补充", prompt: "器材、重量范围或其他信息", text: $information, id: "trial-information")
            field("软件问题", prompt: "计数、声音或操作问题", text: $softwareIssue, id: "trial-software-issue")
            field("训练感受", prompt: "本组感觉怎么样", text: $trainingFeeling, id: "trial-training-feeling")
        }
    }
    private func field(_ title: String, prompt: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(prompt, text: text, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                .accessibilityLabel(title).accessibilityIdentifier(id)
        }
    }
}

struct TrialReviewSummary: View {
    let review: TrialReview
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value = review.information { Text("信息补充：\(value)") }
            if let value = review.softwareIssue { Text("软件问题：\(value)") }
            if let value = review.trainingFeeling { Text("训练感受：\(value)") }
        }.font(.body).accessibilityIdentifier("trial-review-summary")
    }
}

struct ReturnIntervalView: View {
    let rows: [ReturnIntervalRow]
    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("可见返回区间").font(.headline)
                Text("\(rows.filter { $0.seconds != nil }.count) / \(rows.count) 次有测量 · 非完整离心时长")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text("第 \(row.repetition) 次").fixedSize()
                        Spacer(minLength: 16)
                        Text(row.seconds.map { "\($0.formatted(.number.precision(.fractionLength(1)))) 秒" } ?? reason(row.reason))
                            .multilineTextAlignment(.trailing)
                    }.font(.body).monospacedDigit().accessibilityElement(children: .combine)
                }
            }.accessibilityIdentifier("return-interval-summary")
        }
    }
    private func reason(_ value: String?) -> String {
        switch value {
        case "terminal_return_unpublished": return "本观察段末次 · 不统计返回"
        case "trackingGap": return "观测有缺失 · 未测得"
        case "insufficientMotion": return "可见运动不足 · 未测得"
        case "not_recorded": return "未记录返回区间"
        default: return "证据不足 · 未测得"
        }
    }
}
