import Foundation
import FoxTrainingCore
import SwiftUI

/// A writer is acquired only after an explicit training action. Home keeps its reads independent.
@MainActor
final class HomeTrainingDispatcher: ObservableObject {
    struct Presentation: Identifiable {
        let id: UUID
        let store: TrainingStore
        let sessionID: UUID
        let attemptID: UUID?
        let revision: Int
    }

    private enum Failure: LocalizedError {
        case entryRejected(String)
        var errorDescription: String? {
            switch self { case .entryRejected(let message): return message }
        }
    }

    private struct Request: Equatable {
        let card: ServiceCard
        let action: ServiceCardAction
        let id: UUID
    }

    @Published private(set) var pendingRequestID: UUID?
    private let factory: @MainActor () -> TrainingStore
    private var retainedStore: TrainingStore?
    private var pendingRequest: Request?

    init(factory: @escaping @MainActor () -> TrainingStore = { TrainingStore() }) {
        self.factory = factory
    }

    /// The card consumer checks availability immediately before calling this synchronous boundary.
    /// The returned store has already entered the target; presentation must not enter it again.
    func execute(_ card: ServiceCard, action: ServiceCardAction, requestID: UUID) throws -> Presentation {
        try card.validate()
        try card.validate(input: .none, action: action)
        let entry: TrainingEntry
        switch (action.kind, card.target) {
        case (.prepare, .practice(let activity, let side)):
            guard let activity = TrainingActivity(rawValue: activity.rawValue) else {
                throw ServiceCardError.invalidCard
            }
            entry = .prepare(activity, side == .right ? .right : .left, requestID)
        case (.resume, .session(let sessionID, let attemptID)):
            entry = .session(sessionID, .resume, requestID, expectedAttemptID: attemptID)
        case (.review, .session(let sessionID, let attemptID)):
            entry = .session(sessionID, .review, requestID, expectedAttemptID: attemptID)
        default:
            // Viewing a session or history belongs to the read-only Home snapshot.
            throw ServiceCardError.invalidCard
        }

        let request = Request(card: card, action: action, id: requestID)
        if let pendingRequest {
            guard pendingRequest == request else {
                throw Failure.entryRejected("上次切换尚未保存，请先重试上次切换。")
            }
            return try retryPending()
        }

        let store: TrainingStore
        if let retainedStore { store = retainedStore }
        else {
            store = factory()
            retainedStore = store
        }
        guard !store.executionBlocked else {
            throw Failure.entryRejected("上次切换尚未保存，请在原训练页面重试。")
        }
        // A failure deliberately retains this store, including its transaction cutoff and drafts.
        guard store.enter(entry) else {
            if store.executionBlocked {
                pendingRequest = request
                pendingRequestID = requestID
            }
            throw Failure.entryRejected(store.errorMessage ?? "操作未完成，原有训练仍保留。")
        }
        return try presentation(store: store, requestID: requestID)
    }

    /// Completes the original frozen transaction even if its source card has expired or withdrawn.
    /// It never consults a newer card, calls enter again, or creates another request ID.
    func retryPending() throws -> Presentation {
        guard let pendingRequest, let store = retainedStore else {
            throw Failure.entryRejected("没有待恢复的切换。")
        }
        guard store.retrySwitch() else {
            throw Failure.entryRejected(store.errorMessage ?? "上次切换尚未保存，请重试。")
        }
        let result = try presentation(store: store, requestID: pendingRequest.id)
        self.pendingRequest = nil
        pendingRequestID = nil
        return result
    }

    private func presentation(store: TrainingStore, requestID: UUID) throws -> Presentation {
        guard !store.executionBlocked,
              let session = store.archive.currentSession,
              let receipt = store.archive.commandReceipts?.first(where: { $0.command.id == requestID }),
              receipt.sessionID == session.id else {
            throw ServiceCardError.invalidReceipt
        }
        return Presentation(id: requestID, store: store, sessionID: session.id,
            attemptID: session.currentSetAttemptId, revision: store.archive.revision ?? 0)
    }

    /// The presentation owner saves drafts and stops its resources before releasing the writer.
    @discardableResult
    func dismiss() -> Bool {
        guard retainedStore?.executionBlocked != true else { return false }
        pendingRequest = nil
        pendingRequestID = nil
        retainedStore = nil
        return true
    }
}
