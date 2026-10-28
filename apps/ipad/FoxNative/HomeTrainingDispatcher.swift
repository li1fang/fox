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

    private let factory: @MainActor () -> TrainingStore
    private var retainedStore: TrainingStore?

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

        let store: TrainingStore
        if let retainedStore { store = retainedStore }
        else {
            store = factory()
            retainedStore = store
        }
        // A failure deliberately retains this store, including its transaction cutoff and drafts.
        guard store.enter(entry) else {
            throw Failure.entryRejected(store.errorMessage ?? "操作未完成，原有训练仍保留。")
        }
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
        retainedStore = nil
        return true
    }
}
