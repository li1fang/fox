import Foundation

// A consumer contract, not a recommendation engine or a training-fact writer.
public enum ServiceCardError: Error, Equatable {
    case invalidEnvelope, wrongProvider, staleRevision, changedRevision, invalidCard, unavailable, conflictingSubmission, invalidReceipt
}

public struct ServiceCardKey: Codable, Hashable, Sendable {
    public var providerID: String
    public var cardID: String
    public var revision: Int
    public init(providerID: String, cardID: String, revision: Int) {
        self.providerID = providerID; self.cardID = cardID; self.revision = revision
    }
}

public enum ServicePracticeActivity: String, Codable, CaseIterable, Sendable {
    case curl, lateralRaise, latPulldown, kegel
}
public enum ServicePracticeSide: String, Codable, Sendable { case left, right }

public enum ServiceCardTarget: Codable, Equatable, Sendable {
    case question(questionID: String)
    case practice(activity: ServicePracticeActivity, side: ServicePracticeSide?)
    case session(sessionID: UUID, attemptID: UUID?)
    case history
}

public enum ServiceCardKind: String, Codable, Sendable { case question, practiceSuggestion, resume, history }
public enum ServiceCardActionKind: String, Codable, Hashable, Sendable {
    case answer, skip, decline, edit, prepare, resume, view, review
    public var isLocal: Bool { [.prepare, .resume, .view, .review].contains(self) }
}

public struct ServiceCardAction: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ServiceCardActionKind
    public var title: String
    public init(id: String, kind: ServiceCardActionKind, title: String) {
        self.id = id; self.kind = kind; self.title = title
    }
}

public enum ServiceCardAnswerSpec: Codable, Equatable, Sendable {
    case text(maxLength: Int)
    case choice(options: [String])
}
public enum ServiceCardAnswer: Codable, Equatable, Sendable { case text(String), choice(String) }
public enum ServiceCardInput: Codable, Equatable, Sendable { case none, answer(ServiceCardAnswer), edit(String) }

public struct ServiceCard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var revision: Int
    public var kind: ServiceCardKind
    public var title: String
    public var body: String
    public var target: ServiceCardTarget
    public var answerSpec: ServiceCardAnswerSpec?
    public var visible: Bool
    public var visibleFrom: Date
    public var expiresAt: Date
    public var actions: [ServiceCardAction]
    public init(id: String, revision: Int, kind: ServiceCardKind, title: String, body: String = "",
                target: ServiceCardTarget, answerSpec: ServiceCardAnswerSpec? = nil, visible: Bool = true,
                visibleFrom: Date, expiresAt: Date, actions: [ServiceCardAction]) {
        self.id = id; self.revision = revision; self.kind = kind; self.title = title; self.body = body
        self.target = target; self.answerSpec = answerSpec; self.visible = visible
        self.visibleFrom = visibleFrom; self.expiresAt = expiresAt; self.actions = actions
    }
    public func key(providerID: String) -> ServiceCardKey { .init(providerID: providerID, cardID: id, revision: revision) }
    public func validate() throws {
        guard validServiceID(id), revision > 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 300, body.count <= 20_000, visibleFrom.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite, visibleFrom < expiresAt,
              !actions.isEmpty, actions.count <= 12, Set(actions.map(\.id)).count == actions.count,
              actions.allSatisfy({ validServiceID($0.id) && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 100 }) else {
            throw ServiceCardError.invalidCard
        }
        let allowed: Set<ServiceCardActionKind>
        switch (kind, target) {
        case (.question, .question(let questionID)):
            guard validServiceID(questionID), let answerSpec else { throw ServiceCardError.invalidCard }
            switch answerSpec {
            case .text(let limit): guard (1...4000).contains(limit) else { throw ServiceCardError.invalidCard }
            case .choice(let options):
                guard !options.isEmpty, options.count <= 20, Set(options).count == options.count,
                      options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 }) else { throw ServiceCardError.invalidCard }
            }
            allowed = [.answer, .skip]
        case (.practiceSuggestion, .practice(let activity, let side)):
            guard answerSpec == nil, activity != .kegel || side == nil else { throw ServiceCardError.invalidCard }
            allowed = [.prepare, .decline, .edit]
        case (.resume, .session):
            guard answerSpec == nil else { throw ServiceCardError.invalidCard }
            allowed = [.resume, .review, .view]
        case (.history, .history), (.history, .session):
            guard answerSpec == nil else { throw ServiceCardError.invalidCard }
            allowed = [.view]
        default: throw ServiceCardError.invalidCard
        }
        guard actions.allSatisfy({ allowed.contains($0.kind) }) else { throw ServiceCardError.invalidCard }
    }

    public func validate(input: ServiceCardInput, action: ServiceCardAction) throws {
        guard actions.contains(action) else { throw ServiceCardError.invalidCard }
        switch (action.kind, input, answerSpec) {
        case (.answer, .answer(.text(let text)), .text(let limit)):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= limit else { throw ServiceCardError.invalidCard }
        case (.answer, .answer(.choice(let value)), .choice(let options)):
            guard options.contains(value) else { throw ServiceCardError.invalidCard }
        case (.edit, .edit(let text), _):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 4000 else { throw ServiceCardError.invalidCard }
        case (.skip, .none, _), (.decline, .none, _), (.prepare, .none, _), (.resume, .none, _), (.view, .none, _), (.review, .none, _): break
        default: throw ServiceCardError.invalidCard
        }
    }
}

public struct ServiceCardFeed: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var providerID: String
    public var revision: Int
    public var generatedAt: Date
    public var cards: [ServiceCard]
    public init(schemaVersion: Int = 1, providerID: String, revision: Int, generatedAt: Date, cards: [ServiceCard]) {
        self.schemaVersion = schemaVersion; self.providerID = providerID; self.revision = revision
        self.generatedAt = generatedAt; self.cards = cards
    }
    public func validate() throws {
        guard schemaVersion == 1, validServiceID(providerID), revision > 0, generatedAt.timeIntervalSince1970.isFinite,
              cards.count <= 100, Set(cards.map(\.id)).count == cards.count else { throw ServiceCardError.invalidEnvelope }
        try cards.forEach { try $0.validate() }
    }
}

private func validServiceID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
    }
}

public enum ServiceCardAvailability: String, Equatable, Sendable { case available, notYetVisible, expired, withdrawn, stale }
public enum ServiceCardRejection: String, Codable, Sendable { case stale, expired, invalid, conflict, unavailable }
public enum ServiceCardOutcome: Codable, Equatable, Sendable { case accepted, rejected(ServiceCardRejection), retryableFailure }

public struct ServiceCardSubmission: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var key: ServiceCardKey
    public var actionID: String
    public var actionKind: ServiceCardActionKind
    public var target: ServiceCardTarget
    public var input: ServiceCardInput
    public init(id: UUID, key: ServiceCardKey, action: ServiceCardAction, target: ServiceCardTarget, input: ServiceCardInput) {
        self.id = id; self.key = key; actionID = action.id; actionKind = action.kind; self.target = target; self.input = input
    }
}
public struct ServiceCardReceipt: Codable, Equatable, Sendable {
    public var submission: ServiceCardSubmission
    public var outcome: ServiceCardOutcome
    public var receiptID: UUID
    public init(submission: ServiceCardSubmission, outcome: ServiceCardOutcome, receiptID: UUID) {
        self.submission = submission; self.outcome = outcome; self.receiptID = receiptID
    }
}
public struct ServiceCardSubmissionState: Equatable, Sendable {
    public let submission: ServiceCardSubmission
    public var receipt: ServiceCardReceipt?
    // An interrupted/failed transport leaves acceptance unknown, not rejected.
    public var awaitingReceipt: Bool
}

public struct ServiceCardConsumer: Sendable {
    public let providerID: String
    public private(set) var appliedFeed: ServiceCardFeed?
    public private(set) var pendingFeed: ServiceCardFeed?
    public private(set) var latestFeed: ServiceCardFeed?
    public private(set) var drafts: [ServiceCardKey: String] = [:]
    public private(set) var submissions: [UUID: ServiceCardSubmissionState] = [:]
    public private(set) var editing: Set<ServiceCardKey> = []
    public private(set) var reading = false
    private var seen: [ServiceCardKey: ServiceCard] = [:]
    private var greatestRevision: [String: Int] = [:]

    public init(providerID: String) { self.providerID = providerID }

    public mutating func receive(_ feed: ServiceCardFeed) throws {
        try feed.validate()
        guard feed.providerID == providerID else { throw ServiceCardError.wrongProvider }
        if let latestFeed {
            guard feed.revision >= latestFeed.revision else { throw ServiceCardError.staleRevision }
            if feed.revision == latestFeed.revision {
                guard feed == latestFeed else { throw ServiceCardError.changedRevision }
                return
            }
        }
        // Validate the entire snapshot before publishing even its withdrawal information.
        for card in feed.cards {
            let key = card.key(providerID: providerID)
            if let previous = seen[key], previous != card { throw ServiceCardError.changedRevision }
            if let revision = greatestRevision[card.id], card.revision < revision { throw ServiceCardError.staleRevision }
        }
        for card in feed.cards {
            seen[card.key(providerID: providerID)] = card
            greatestRevision[card.id] = card.revision
        }
        latestFeed = feed
        if appliedFeed == nil || (editing.isEmpty && !reading) { appliedFeed = feed; pendingFeed = nil }
        else { pendingFeed = feed }
    }

    public mutating func setDraft(_ text: String, for key: ServiceCardKey) {
        guard seen[key] != nil else { return }
        drafts[key] = text
    }
    public mutating func setEditing(_ active: Bool, key: ServiceCardKey) {
        if active, seen[key] != nil { editing.insert(key) } else { editing.remove(key) }
        applyPendingIfSafe()
    }
    public mutating func setReading(_ active: Bool) {
        reading = active
        applyPendingIfSafe()
    }
    private mutating func applyPendingIfSafe() {
        if editing.isEmpty, !reading, let pendingFeed { appliedFeed = pendingFeed; self.pendingFeed = nil }
    }
    public func card(for key: ServiceCardKey) -> ServiceCard? { seen[key] }
    public func availability(of key: ServiceCardKey, at now: Date) -> ServiceCardAvailability {
        guard key.providerID == providerID, let current = latestFeed?.cards.first(where: { $0.id == key.cardID }), current.visible else { return .withdrawn }
        guard current.revision == key.revision else { return .stale }
        guard now >= current.visibleFrom else { return .notYetVisible }
        guard now < current.expiresAt else { return .expired }
        return .available
    }

    public func action(key: ServiceCardKey, actionID: String, at now: Date) throws -> (ServiceCard, ServiceCardAction) {
        guard availability(of: key, at: now) == .available, let card = seen[key],
              let action = card.actions.first(where: { $0.id == actionID }) else { throw ServiceCardError.unavailable }
        return (card, action)
    }

    public mutating func beginSubmission(key: ServiceCardKey, actionID: String, input: ServiceCardInput = .none,
                                         id: UUID? = nil, at now: Date) throws -> ServiceCardSubmission {
        let (card, action) = try action(key: key, actionID: actionID, at: now)
        guard !action.kind.isLocal else { throw ServiceCardError.invalidCard }
        try card.validate(input: input, action: action)
        let proposed = ServiceCardSubmission(id: id ?? UUID(), key: key, action: action, target: card.target, input: input)
        if let id, let previous = submissions[id] {
            guard previous.submission == proposed else { throw ServiceCardError.conflictingSubmission }
            return previous.submission
        }
        if id == nil, let previous = submissions.values.first(where: {
            $0.submission.key == key && $0.submission.actionID == actionID && $0.submission.input == input
        }) { return previous.submission }
        submissions[proposed.id] = .init(submission: proposed, receipt: nil, awaitingReceipt: true)
        return proposed
    }

    public mutating func markAwaitingReceipt(_ id: UUID) {
        guard var state = submissions[id] else { return }
        if let receipt = state.receipt, receipt.outcome != .retryableFailure { return }
        state.awaitingReceipt = true; submissions[id] = state
    }
    public mutating func receive(_ receipt: ServiceCardReceipt) throws {
        guard var state = submissions[receipt.submission.id], state.submission == receipt.submission else { throw ServiceCardError.invalidReceipt }
        if let previous = state.receipt, previous.outcome != .retryableFailure {
            // A delayed transient failure cannot erase an accepted or terminal rejected receipt.
            if receipt.outcome == .retryableFailure { return }
            guard previous == receipt else { throw ServiceCardError.invalidReceipt }
            return
        }
        state.receipt = receipt; state.awaitingReceipt = receipt.outcome == .retryableFailure
        submissions[receipt.submission.id] = state
    }
}

public protocol ServiceCardProvider: Sendable {
    var providerID: String { get }
    var isSynthetic: Bool { get }
    func fetchFeed() async throws -> ServiceCardFeed
    func submit(_ submission: ServiceCardSubmission) async throws -> ServiceCardReceipt
    func query(_ submissionID: UUID) async throws -> ServiceCardReceipt?
}

// Explicit test/design injection only. Production does not create a default provider.
public actor SyntheticServiceCardProvider: ServiceCardProvider {
    public nonisolated let providerID: String
    public nonisolated let isSynthetic = true
    private var feed: ServiceCardFeed
    private let now: @Sendable () -> Date
    private let delayNanoseconds: UInt64
    private var failuresBeforeAcceptance: Int
    private var dropAcceptedReceipts: Int
    private var receipts: [UUID: ServiceCardReceipt] = [:]
    public init(feed: ServiceCardFeed, now: @escaping @Sendable () -> Date = { Date() }, delayNanoseconds: UInt64 = 0,
                failuresBeforeAcceptance: Int = 0, dropAcceptedReceipts: Int = 0) {
        self.feed = feed; providerID = feed.providerID; self.now = now
        self.delayNanoseconds = delayNanoseconds; self.failuresBeforeAcceptance = max(0, failuresBeforeAcceptance)
        self.dropAcceptedReceipts = max(0, dropAcceptedReceipts)
    }
    public func replaceFeed(_ feed: ServiceCardFeed) { self.feed = feed }
    private func delay() async throws {
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        try Task.checkCancellation()
    }
    public func fetchFeed() async throws -> ServiceCardFeed { try await delay(); return feed }
    public func query(_ submissionID: UUID) async throws -> ServiceCardReceipt? { try await delay(); return receipts[submissionID] }
    public func submit(_ submission: ServiceCardSubmission) async throws -> ServiceCardReceipt {
        try await delay()
        if let receipt = receipts[submission.id] {
            guard receipt.submission == submission else { throw ServiceCardError.conflictingSubmission }
            return receipt
        }
        if failuresBeforeAcceptance > 0 { failuresBeforeAcceptance -= 1; throw ServiceCardError.unavailable }
        var model = ServiceCardConsumer(providerID: providerID)
        try model.receive(feed)
        let outcome: ServiceCardOutcome
        switch model.availability(of: submission.key, at: now()) {
        case .expired: outcome = .rejected(.expired)
        case .stale: outcome = .rejected(.stale)
        case .withdrawn, .notYetVisible: outcome = .rejected(.unavailable)
        case .available:
            do {
                let verified = try model.beginSubmission(key: submission.key, actionID: submission.actionID,
                    input: submission.input, id: submission.id, at: now())
                outcome = verified == submission ? .accepted : .rejected(.invalid)
            } catch { outcome = .rejected(.invalid) }
        }
        let receipt = ServiceCardReceipt(submission: submission, outcome: outcome, receiptID: UUID())
        receipts[submission.id] = receipt
        if outcome == .accepted, dropAcceptedReceipts > 0 { dropAcceptedReceipts -= 1; throw ServiceCardError.unavailable }
        return receipt
    }
}
