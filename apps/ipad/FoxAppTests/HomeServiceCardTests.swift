import XCTest
import FoxTrainingCore
@testable import Fox

@MainActor
final class HomeServiceCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func card(_ id: String, choice: Bool = false) -> ServiceCard {
        ServiceCard(id: id, revision: 1, kind: .question, title: "合成问题 \(id)",
            target: .question(questionID: id), answerSpec: choice ? .choice(options: ["是", "否"]) : .text(maxLength: 100),
            visibleFrom: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(100),
            actions: [.init(id: "answer", kind: .answer, title: "提交")])
    }
    private func feed(_ cards: [ServiceCard], revision: Int) -> ServiceCardFeed {
        .init(providerID: "held", revision: revision, generatedAt: now, cards: cards)
    }

    func testDelayedFeedCannotReplaceChoiceUntilExplicitSelectionAndReadingBoundaries() async {
        let a = card("a", choice: true), b = card("b")
        let provider = HeldServiceCardProvider(feed: feed([a, b], revision: 1))
        let store = HomeServiceCardStore(provider: provider, now: { self.now })
        await store.refresh()
        await provider.holdNextFetch()
        let pending = Task { await store.refresh() }
        await provider.waitForPendingFetch()
        store.beginChoiceEditing(a)
        store.setDraft("否", card: a)
        await provider.deliver(feed([b], revision: 2))
        await pending.value
        XCTAssertEqual(store.cards.map(\.id), ["a", "b"])
        XCTAssertTrue(store.isChoiceEditing(a))
        XCTAssertEqual(store.availability(a), .withdrawn)
        XCTAssertFalse(store.applyPendingUpdates(), "Cannot move an open selection editor")
        store.endChoiceEditing(a)
        XCTAssertEqual(store.cards.map(\.id), ["a", "b"], "Finishing the picker does not finish reading")
        XCTAssertTrue(store.applyPendingUpdates())
        XCTAssertEqual(store.cards.map(\.id), ["b"])
        XCTAssertEqual(store.consumer.drafts[store.key(a)], "否")
    }

    func testDelayedFeedStaysPendingDuringReadingAndDoesNotBorrowNewQuestionDraft() async {
        let a = card("a"), b = card("b")
        let provider = HeldServiceCardProvider(feed: feed([a, b], revision: 1))
        let store = HomeServiceCardStore(provider: provider, now: { self.now })
        await store.refresh(); store.setDraft("原问题输入", card: a)
        await provider.holdNextFetch()
        let pending = Task { await store.refresh() }
        await provider.waitForPendingFetch()
        var newer = a; newer.revision = 2; newer.title = "新版问题"
        await provider.deliver(feed([b, newer], revision: 2)); await pending.value
        XCTAssertEqual(store.cards.map(\.id), ["a", "b"])
        XCTAssertEqual(store.consumer.appliedFeed?.revision, 1)
        XCTAssertEqual(store.consumer.pendingFeed?.revision, 2)
        XCTAssertEqual(store.availability(a), .stale)
        XCTAssertTrue(store.applyPendingUpdates())
        XCTAssertEqual(store.cards.map(\.id), ["b", "a"])
        XCTAssertEqual(store.draft(newer), "")
        XCTAssertEqual(store.consumer.drafts[store.key(a)], "原问题输入")
    }

    func testScheduledCardWaitsForReadingBoundaryButExpiryDisablesImmediately() async {
        let a = card("a")
        var scheduled = card("scheduled"); scheduled.visibleFrom = now.addingTimeInterval(10)
        let provider = HeldServiceCardProvider(feed: feed([a, scheduled], revision: 1))
        var current = now
        let store = HomeServiceCardStore(provider: provider, now: { current })
        await store.refresh()
        XCTAssertEqual(store.cards.map(\.id), ["a"])
        current = now.addingTimeInterval(11); store.tick()
        XCTAssertEqual(store.cards.map(\.id), ["a"], "A clock tick must not insert a row under the reader")
        XCTAssertTrue(store.hasPendingUpdates)
        XCTAssertTrue(store.applyPendingUpdates())
        XCTAssertEqual(store.cards.map(\.id), ["a", "scheduled"])
        current = now.addingTimeInterval(101); store.tick()
        XCTAssertEqual(store.availability(a), .expired)
        XCTAssertEqual(store.availability(scheduled), .expired)
        XCTAssertEqual(store.cards.map(\.id), ["a", "scheduled"], "Expiry changes eligibility without moving rows")
    }
}

private actor HeldServiceCardProvider: ServiceCardProvider {
    nonisolated let providerID = "held"
    nonisolated let isSynthetic = true
    private var feed: ServiceCardFeed
    private var held = false
    private var pending: CheckedContinuation<ServiceCardFeed, Error>?
    private var entered: CheckedContinuation<Void, Never>?
    init(feed: ServiceCardFeed) { self.feed = feed }
    func holdNextFetch() { held = true }
    func waitForPendingFetch() async {
        if pending != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func deliver(_ value: ServiceCardFeed) {
        feed = value; pending?.resume(returning: value); pending = nil
    }
    func fetchFeed() async throws -> ServiceCardFeed {
        guard held else { return feed }
        held = false
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation; entered?.resume(); entered = nil
        }
    }
    func submit(_ submission: ServiceCardSubmission) async throws -> ServiceCardReceipt { throw ServiceCardError.unavailable }
    func query(_ submissionID: UUID) async throws -> ServiceCardReceipt? { nil }
}
