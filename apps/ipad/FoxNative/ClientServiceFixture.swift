import Foundation
import FoxTrainingCore

/// Synthetic UI input only; this does not configure a production service or make recommendations.
@MainActor
enum ClientServiceFixture {
    static func makeIfEnabled() -> HomeServiceCardStore? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["FOX_UI_TESTING"] == "1", environment["FOX_UI_SERVICE_CARDS"] == "foundation" else { return nil }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let from = now.addingTimeInterval(-100), until = now.addingTimeInterval(3600)
        let cards = [
            ServiceCard(id: "foundation-answer", revision: 1, kind: .question, title: "合成问题：今天想怎样记录？",
                body: "可回答，也可跳过；不会据此修改训练。", target: .question(questionID: "record-preference"),
                answerSpec: .choice(options: ["只看文字", "文字与照片"]), visibleFrom: from, expiresAt: until,
                actions: [.init(id: "answer", kind: .answer, title: "提交回答"), .init(id: "skip", kind: .skip, title: "暂时跳过")]),
            ServiceCard(id: "foundation-skip", revision: 1, kind: .question, title: "合成问题：还有想补充的吗？",
                body: "不回答不会生成回答事实。", target: .question(questionID: "optional-note"),
                answerSpec: .text(maxLength: 200), visibleFrom: from, expiresAt: until,
                actions: [.init(id: "answer", kind: .answer, title: "提交补充"), .init(id: "skip", kind: .skip, title: "跳过补充")]),
            ServiceCard(id: "foundation-kegel", revision: 1, kind: .practiceSuggestion, title: "合成建议：试练一组凯格尔运动",
                body: "节奏引导，不使用相机。", target: .practice(activity: .kegel, side: nil),
                visibleFrom: from, expiresAt: until,
                actions: [.init(id: "prepare", kind: .prepare, title: "准备这组凯格尔运动"),
                          .init(id: "decline", kind: .decline, title: "不采用建议"),
                          .init(id: "edit", kind: .edit, title: "更正建议")]),
            ServiceCard(id: "foundation-expired", revision: 1, kind: .practiceSuggestion, title: "合成已到期建议",
                body: "这条建议已到期，不能开始。", target: .practice(activity: .curl, side: .left),
                visibleFrom: from, expiresAt: now.addingTimeInterval(-1),
                actions: [.init(id: "prepare", kind: .prepare, title: "已到期的训练入口")])
        ]
        let feed = ServiceCardFeed(providerID: "foundation-synthetic", revision: 1, generatedAt: now, cards: cards)
        let provider = SyntheticServiceCardProvider(feed: feed, now: { now })
        return HomeServiceCardStore(provider: provider, now: { now })
        #else
        return nil
        #endif
    }
}
