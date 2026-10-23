import Foundation

/// Bounded waiting queue. Once cancelled, expired or taken, a cue ID cannot be replayed.
/// A new attempt owns a new queue; output adapters also cancel speech already in progress.
public struct GuidanceQueue {
    public private(set) var pending: [GuidanceCue] = []
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private let capacity: Int
    public init(capacity: Int = 3) { self.capacity = max(1, min(capacity, 10)) }
    @discardableResult public mutating func enqueue(_ cue: GuidanceCue) -> [GuidanceCue] {
        guard !seen.contains(cue.id) else { return [] }
        seen.insert(cue.id); seenOrder.append(cue.id)
        if seenOrder.count > 4096 { seen.remove(seenOrder.removeFirst()) }
        pending.append(cue)
        pending.sort { $0.priority == $1.priority ? $0.createdAt > $1.createdAt : $0.priority > $1.priority }
        let evicted = Array(pending.dropFirst(capacity))
        if pending.count > capacity { pending.removeLast(pending.count - capacity) }
        return evicted
    }
    @discardableResult public mutating func cancelAll() -> [GuidanceCue] {
        let cancelled = pending; pending.removeAll(); return cancelled
    }
    @discardableResult public mutating func discardInvalid(at time: Double, context: GuidanceContext,
                                                          stage: GuidanceStage, phaseToken: String?, observationAvailable: Bool? = nil) -> [GuidanceCue] {
        let cancelled = pending.filter { !$0.isValid(at: time, context: context, stage: stage, phaseToken: phaseToken, observationAvailable: observationAvailable) }
        pending.removeAll { !$0.isValid(at: time, context: context, stage: stage, phaseToken: phaseToken, observationAvailable: observationAvailable) }
        return cancelled
    }
    public mutating func takeNext(at time: Double, context: GuidanceContext, stage: GuidanceStage, phaseToken: String?, observationAvailable: Bool? = nil) -> GuidanceCue? {
        discardInvalid(at: time, context: context, stage: stage, phaseToken: phaseToken, observationAvailable: observationAvailable)
        return pending.isEmpty ? nil : pending.removeFirst()
    }
}
