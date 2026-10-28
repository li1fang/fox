import XCTest
import FoxTrainingCore
@testable import Fox

@MainActor
final class HomeTrainingDispatcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore(writer: ((Data, URL) throws -> Void)? = nil) -> TrainingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HomeTrainingDispatcher-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = TrainingStore(archiveURL: root.appendingPathComponent("training.json"),
            diagnosticRoot: root.appendingPathComponent("diagnostics"), writer: writer)
        store.workoutVision.controller.enableReplay(clock: VisionReplayClock())
        return store
    }

    private func card(_ kind: ServiceCardKind, target: ServiceCardTarget,
                      action: ServiceCardActionKind) -> ServiceCard {
        ServiceCard(id: "local-action", revision: 1, kind: kind, title: "合成本地操作",
            target: target, visibleFrom: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(100),
            actions: [.init(id: "open", kind: action, title: "打开")])
    }

    func testFactoryIsLazyAndReadOnlyOrUnlistedActionsNeverCreateWriter() throws {
        var factoryCalls = 0
        let dispatcher = HomeTrainingDispatcher {
            factoryCalls += 1
            return self.makeStore()
        }
        XCTAssertEqual(factoryCalls, 0)
        let history = card(.history, target: .history, action: .view)
        XCTAssertThrowsError(try dispatcher.execute(history, action: history.actions[0], requestID: UUID()))
        let sessionView = card(.history, target: .session(sessionID: UUID(), attemptID: nil), action: .view)
        XCTAssertThrowsError(try dispatcher.execute(sessionView, action: sessionView.actions[0], requestID: UUID()))
        let practice = card(.practiceSuggestion, target: .practice(activity: .kegel, side: nil), action: .prepare)
        let unlisted = ServiceCardAction(id: "another", kind: .prepare, title: "打开")
        XCTAssertThrowsError(try dispatcher.execute(practice, action: unlisted, requestID: UUID()))
        XCTAssertTrue(dispatcher.dismiss())
        XCTAssertEqual(factoryCalls, 0)
    }

    func testPrepareReturnsOnlyTheCommittedSessionAndAttempt() throws {
        let store = makeStore(), requestID = UUID()
        var factoryCalls = 0
        let dispatcher = HomeTrainingDispatcher { factoryCalls += 1; return store }
        let practice = card(.practiceSuggestion, target: .practice(activity: .curl, side: .right), action: .prepare)
        let result = try dispatcher.execute(practice, action: practice.actions[0], requestID: requestID)
        let session = try XCTUnwrap(store.archive.currentSession)
        let persisted = try LocalTrainingRepository.decoder().decode(TrainingArchive.self, from: Data(contentsOf: store.fileURL))
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(result.store === store)
        XCTAssertEqual(result.id, requestID)
        XCTAssertEqual(result.sessionID, session.id)
        XCTAssertEqual(result.attemptID, session.currentSetAttemptId)
        XCTAssertNotNil(result.attemptID)
        XCTAssertEqual(result.revision, persisted.revision)
        XCTAssertEqual(persisted.currentSession?.id, result.sessionID)
        XCTAssertEqual(persisted.commandReceipts?.first { $0.command.id == requestID }?.sessionID, result.sessionID)
        XCTAssertEqual(session.executionStart, .notStarted)
        XCTAssertEqual(session.plan, TrainingCapabilities.trial(.curl, arm: .right))
        let repeated = try dispatcher.execute(practice, action: practice.actions[0], requestID: requestID)
        XCTAssertEqual(repeated.sessionID, result.sessionID)
        XCTAssertEqual(store.archive.sessions.count, 1)
    }

    func testConsumerFailureRetainsStoreAndOriginalRequestUntilRetryCommits() async throws {
        var fail = true
        let store = makeStore { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        var factoryCalls = 0
        let dispatcher = HomeTrainingDispatcher { factoryCalls += 1; return store }
        let practice = card(.practiceSuggestion, target: .practice(activity: .kegel, side: nil), action: .prepare)
        let feed = ServiceCardFeed(providerID: "dispatcher-test", revision: 1, generatedAt: now, cards: [practice])
        let consumer = HomeServiceCardStore(provider: SyntheticServiceCardProvider(feed: feed), now: { self.now })
        await consumer.refresh()
        var requests: [UUID] = []
        var presented: HomeTrainingDispatcher.Presentation?
        let execute: (ServiceCard, ServiceCardAction, UUID) async throws -> Void = { card, action, id in
            requests.append(id)
            presented = try dispatcher.execute(card, action: action, requestID: id)
        }
        await consumer.performLocal(card: practice, action: practice.actions[0], execute: execute)
        let key = consumer.localKey(card: practice, action: practice.actions[0])
        XCTAssertNotNil(consumer.localErrors[key])
        XCTAssertNil(presented, "Routing alone must not report a completed local action")
        XCTAssertTrue(store.executionBlocked)
        XCTAssertFalse(dispatcher.dismiss(), "The failed transaction owns the retained store")
        XCTAssertEqual(store.archive.sessions.count, 0)
        fail = false
        await consumer.performLocal(card: practice, action: practice.actions[0], execute: execute)
        let result = try XCTUnwrap(presented)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(result.store === store)
        XCTAssertNil(consumer.localErrors[key])
        XCTAssertTrue(consumer.localBusy.isEmpty)
        XCTAssertFalse(store.executionBlocked)
        XCTAssertEqual(result.id, requests.first)
        XCTAssertEqual(result.sessionID, store.archive.currentSession?.id)
        XCTAssertEqual(store.archive.sessions.count, 1)
    }

    func testReviewRejectsOldAttemptWithoutChangingForegroundOrRevision() throws {
        let store = makeStore()
        store.start()
        store.setVisionEnabled(false)
        let a = try XCTUnwrap(store.session), oldAttempt = try XCTUnwrap(a.currentSetAttemptId)
        XCTAssertTrue(store.updateSession {
            try $0.startSet(at: Date()); try $0.finishSet(at: Date())
            try $0.submit(reps: 1, feedback: [], notes: "", at: Date())
        })
        XCTAssertTrue(store.updateSession {
            try $0.readyAfterRest(at: Date()); try $0.startSet(at: Date()); try $0.finishSet(at: Date())
        })
        XCTAssertNotEqual(store.session?.currentSetAttemptId, oldAttempt)
        XCTAssertTrue(store.preparePractice(.kegel, requestID: UUID()))
        let before = store.archive, bytes = try Data(contentsOf: store.fileURL)
        let dispatcher = HomeTrainingDispatcher { store }
        let review = card(.resume, target: .session(sessionID: a.id, attemptID: oldAttempt), action: .review)
        XCTAssertThrowsError(try dispatcher.execute(review, action: review.actions[0], requestID: UUID()))
        XCTAssertEqual(store.archive, before)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        XCTAssertFalse(store.executionBlocked)
    }

    func testResumeReturnsExactSessionInsteadOfCurrentForeground() throws {
        let store = makeStore()
        XCTAssertTrue(store.preparePractice(.kegel, requestID: UUID()))
        XCTAssertTrue(store.updateSession { try $0.startSet(at: Date()) })
        let a = try XCTUnwrap(store.session)
        XCTAssertTrue(store.preparePractice(.curl, requestID: UUID()))
        XCTAssertNotEqual(store.session?.id, a.id)
        let dispatcher = HomeTrainingDispatcher { store }, requestID = UUID()
        let resume = card(.resume, target: .session(sessionID: a.id, attemptID: a.currentSetAttemptId), action: .resume)
        let result = try dispatcher.execute(resume, action: resume.actions[0], requestID: requestID)
        XCTAssertEqual(result.sessionID, a.id)
        XCTAssertEqual(result.attemptID, a.currentSetAttemptId)
        XCTAssertEqual(store.archive.currentSession?.id, a.id)
        XCTAssertEqual(store.archive.sessions.count, 2)
        XCTAssertEqual(store.archive.commandReceipts?.first { $0.command.id == requestID }?.sessionID, a.id)
    }

    func testReviewReturnsExactUnconfirmedAttempt() throws {
        let store = makeStore()
        XCTAssertTrue(store.preparePractice(.kegel, requestID: UUID()))
        XCTAssertTrue(store.updateSession { try $0.startSet(at: Date()); try $0.finishSet(at: Date()) })
        let a = try XCTUnwrap(store.session)
        XCTAssertTrue(store.preparePractice(.curl, requestID: UUID()))
        let dispatcher = HomeTrainingDispatcher { store }
        let review = card(.resume, target: .session(sessionID: a.id, attemptID: a.currentSetAttemptId), action: .review)
        let result = try dispatcher.execute(review, action: review.actions[0], requestID: UUID())
        XCTAssertEqual(result.sessionID, a.id)
        XCTAssertEqual(result.attemptID, a.currentSetAttemptId)
        XCTAssertEqual(store.archive.currentSession?.stage, .feedback)
        XCTAssertEqual(store.archive.sessions.count, 2)
    }

    func testDismissReleasesSuccessfulStoreWithoutCreatingAnotherWriter() throws {
        var factoryCalls = 0
        let dispatcher = HomeTrainingDispatcher { factoryCalls += 1; return self.makeStore() }
        let practice = card(.practiceSuggestion, target: .practice(activity: .kegel, side: nil), action: .prepare)
        let first = try dispatcher.execute(practice, action: practice.actions[0], requestID: UUID())
        XCTAssertTrue(dispatcher.dismiss())
        XCTAssertEqual(factoryCalls, 1)
        let second = try dispatcher.execute(practice, action: practice.actions[0], requestID: UUID())
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertFalse(first.store === second.store)
    }
}
