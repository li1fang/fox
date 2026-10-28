import Foundation
import XCTest
@testable import FoxTrainingCore

final class ServiceCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func question(_ id: String = "q", revision: Int = 1) -> ServiceCard {
        ServiceCard(id: id, revision: revision, kind: .question, title: "合成问题",
            target: .question(questionID: id), answerSpec: .text(maxLength: 100),
            visibleFrom: now.addingTimeInterval(-10), expiresAt: now.addingTimeInterval(100),
            actions: [ServiceCardAction(id: "answer", kind: .answer, title: "提交"),
                      ServiceCardAction(id: "skip", kind: .skip, title: "跳过")])
    }
    private func feed(_ cards: [ServiceCard], revision: Int = 1) -> ServiceCardFeed {
        ServiceCardFeed(providerID: "synthetic", revision: revision, generatedAt: now, cards: cards)
    }

    func testFeedRejectsIdentityVersionTargetAndChangedContentWithoutPartialApply() throws {
        var model = ServiceCardConsumer(providerID: "synthetic")
        let original = feed([question()]); try model.receive(original)
        var invalid = original; invalid.cards.append(question())
        XCTAssertThrowsError(try model.receive(invalid))
        invalid = original; invalid.revision = 2; invalid.cards[0].title = "偷改版本"
        XCTAssertThrowsError(try model.receive(invalid))
        invalid = original; invalid.providerID = "other"
        XCTAssertThrowsError(try model.receive(invalid))
        invalid = original; invalid.schemaVersion = 99
        XCTAssertThrowsError(try model.receive(invalid))
        invalid = original; invalid.cards[0].target = .history
        XCTAssertThrowsError(try model.receive(invalid))
        XCTAssertEqual(model.appliedFeed, original)
    }

    func testEditingDefersReorderButWithdrawalAndExpiryDisableImmediatelyKeepingDraft() throws {
        var model = ServiceCardConsumer(providerID: "synthetic")
        let a = question("a"), b = question("b"), key = a.key(providerID: "synthetic")
        try model.receive(feed([a, b])); model.setDraft("未提交原文", for: key)
        model.setEditing(true, key: key)
        try model.receive(feed([b, a], revision: 2))
        XCTAssertEqual(model.appliedFeed?.cards.map(\.id), ["a", "b"])
        XCTAssertEqual(model.pendingFeed?.revision, 2)
        try model.receive(feed([b], revision: 3))
        XCTAssertEqual(model.availability(of: key, at: now), .withdrawn)
        XCTAssertThrowsError(try model.beginSubmission(key: key, actionID: "answer", input: .answer(.text("x")), at: now))
        XCTAssertEqual(model.drafts[key], "未提交原文")
        model.setEditing(false, key: key)
        XCTAssertEqual(model.appliedFeed?.cards.map(\.id), ["b"])
        XCTAssertNil(model.pendingFeed)
        XCTAssertEqual(model.availability(of: b.key(providerID: "synthetic"), at: now.addingTimeInterval(101)), .expired)
    }

    func testNewQuestionRevisionDoesNotInheritAnswerAndOlderFeedCannotReturn() throws {
        var model = ServiceCardConsumer(providerID: "synthetic")
        let old = question(); try model.receive(feed([old]))
        model.setDraft("旧问题答案", for: old.key(providerID: "synthetic"))
        let new = question(revision: 2); try model.receive(feed([new], revision: 2))
        XCTAssertNil(model.drafts[new.key(providerID: "synthetic")])
        XCTAssertEqual(model.availability(of: old.key(providerID: "synthetic"), at: now), .stale)
        XCTAssertThrowsError(try model.receive(feed([old])))
        XCTAssertThrowsError(try model.receive(feed([old], revision: 3)))
    }

    func testSubmissionReusesIdentityRejectsChangedPayloadAndPreservesAcceptedAfterExpiry() throws {
        var model = ServiceCardConsumer(providerID: "synthetic")
        let card = question(), key = card.key(providerID: "synthetic")
        try model.receive(feed([card]))
        let first = try model.beginSubmission(key: key, actionID: "answer", input: .answer(.text("原始回答")), at: now)
        let retry = try model.beginSubmission(key: key, actionID: "answer", input: .answer(.text("原始回答")), at: now)
        XCTAssertEqual(first, retry)
        XCTAssertThrowsError(try model.beginSubmission(key: key, actionID: "answer", input: .answer(.text("变更")), id: first.id, at: now))
        let receipt = ServiceCardReceipt(submission: first, outcome: .accepted, receiptID: UUID())
        try model.receive(receipt)
        try model.receive(ServiceCardReceipt(submission: first, outcome: .retryableFailure, receiptID: UUID()))
        XCTAssertEqual(model.submissions[first.id]?.receipt, receipt)
        XCTAssertEqual(model.availability(of: key, at: now.addingTimeInterval(101)), .expired)
        var wrong = first; wrong.key.cardID = "other"
        XCTAssertThrowsError(try model.receive(ServiceCardReceipt(submission: wrong, outcome: .accepted, receiptID: UUID())))
    }

    func testSilenceSkipDeclineAndEditAreDistinctAndNeverMutateTraining() throws {
        var model = ServiceCardConsumer(providerID: "synthetic")
        let card = question(); try model.receive(feed([card]))
        XCTAssertTrue(model.submissions.isEmpty)
        XCTAssertThrowsError(try model.beginSubmission(key: card.key(providerID: "synthetic"), actionID: "answer", input: .answer(.text("  ")), at: now))
        let skip = try model.beginSubmission(key: card.key(providerID: "synthetic"), actionID: "skip", at: now)
        XCTAssertEqual(skip.input, .none)
        var suggestion = card; suggestion.id = "practice"; suggestion.kind = .practiceSuggestion
        suggestion.target = .practice(activity: .curl, side: .left); suggestion.answerSpec = nil
        suggestion.actions = [.init(id: "decline", kind: .decline, title: "不采用"), .init(id: "edit", kind: .edit, title: "更正建议")]
        try model.receive(feed([card, suggestion], revision: 2))
        let edit = try model.beginSubmission(key: suggestion.key(providerID: "synthetic"), actionID: "edit", input: .edit("改为右侧"), at: now)
        XCTAssertEqual(edit.target, .practice(activity: .curl, side: .left))
        XCTAssertEqual(edit.input, .edit("改为右侧"))
    }

    func testSyntheticProviderLostReceiptReconcilesSameSubmissionAfterWithdrawal() async throws {
        let card = question(), initial = feed([card])
        let fixedNow = now
        let provider = SyntheticServiceCardProvider(feed: initial, now: { fixedNow }, dropAcceptedReceipts: 1)
        var model = ServiceCardConsumer(providerID: "synthetic"); try model.receive(initial)
        let submission = try model.beginSubmission(key: card.key(providerID: "synthetic"), actionID: "answer", input: .answer(.text("保留原文")), at: now)
        do { _ = try await provider.submit(submission); XCTFail("Response must be lost") } catch {}
        await provider.replaceFeed(feed([], revision: 2))
        let queried = try await provider.query(submission.id)
        let receipt = try XCTUnwrap(queried)
        XCTAssertEqual(receipt.outcome, .accepted)
        let retried = try await provider.submit(submission)
        XCTAssertEqual(retried, receipt)
        var changed = submission; changed.input = .answer(.text("不同内容"))
        do { _ = try await provider.submit(changed); XCTFail("Same ID must not accept changed payload") } catch {}
    }

    func testSyntheticFailureBeforeAcceptanceAndConcurrentRetryCreateOneReceipt() async throws {
        let card = question(), initial = feed([card]), fixedNow = now
        let provider = SyntheticServiceCardProvider(feed: initial, now: { fixedNow },
            delayNanoseconds: 1_000_000, failuresBeforeAcceptance: 1)
        var model = ServiceCardConsumer(providerID: "synthetic"); try model.receive(initial)
        let request = try model.beginSubmission(key: card.key(providerID: "synthetic"), actionID: "skip", at: now)
        do { _ = try await provider.submit(request); XCTFail("Injected failure") } catch {}
        let missing = try await provider.query(request.id); XCTAssertNil(missing)
        async let first = provider.submit(request)
        async let second = provider.submit(request)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        try model.receive(a); try model.receive(b)
        XCTAssertEqual(model.submissions.count, 1)
    }

    func testTypedChoiceAndActionValidationRejectUnknownOrMismatchedCommands() throws {
        var card = question(); card.answerSpec = .choice(options: ["是", "否"])
        var model = ServiceCardConsumer(providerID: "synthetic"); try model.receive(feed([card]))
        let key = card.key(providerID: "synthetic")
        XCTAssertThrowsError(try model.beginSubmission(key: key, actionID: "answer", input: .answer(.text("是")), at: now))
        XCTAssertThrowsError(try model.beginSubmission(key: key, actionID: "answer", input: .answer(.choice("也许")), at: now))
        XCTAssertThrowsError(try model.beginSubmission(key: key, actionID: "unknown", at: now))
        _ = try model.beginSubmission(key: key, actionID: "answer", input: .answer(.choice("是")), at: now)
        var bad = feed([card], revision: 2)
        bad.cards[0].actions = [.init(id: "prepare", kind: .prepare, title: "开始")]
        XCTAssertThrowsError(try model.receive(bad))
        XCTAssertThrowsError(try JSONDecoder().decode(ServiceCardActionKind.self, from: Data("\"script\"".utf8)))
    }
}
