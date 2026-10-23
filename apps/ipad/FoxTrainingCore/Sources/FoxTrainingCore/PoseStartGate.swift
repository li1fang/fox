import Foundation

public enum PoseStartState: Equatable {
    case idle, waiting, countdown(Int), ready
    public var isPreparing: Bool {
        switch self {
        case .waiting, .countdown: return true
        case .idle, .ready: return false
        }
    }
}

public struct PoseStartGate {
    public private(set) var state = PoseStartState.idle
    private var lastTimestamp: Double?
    private var stableSince: Double?
    private var countdownSince: Double?
    private var lastReady: Double?
    private let lossTolerance: Double
    public init(lossTolerance: Double = 0) { precondition(lossTolerance.isFinite && (0...0.5).contains(lossTolerance)); self.lossTolerance = lossTolerance }

    public mutating func arm() {
        lastTimestamp = nil; stableSince = nil; countdownSince = nil; lastReady = nil
        state = .waiting
    }

    public mutating func cancel() {
        lastTimestamp = nil; stableSince = nil; countdownSince = nil; lastReady = nil
        state = .idle
    }

    public mutating func invalidate() {
        if state.isPreparing { arm() }
    }

    @discardableResult public mutating func process(timestamp: Double, poseReady: Bool) -> PoseStartState {
        guard state.isPreparing, timestamp.isFinite,
              lastTimestamp.map({ timestamp > $0 }) ?? true else { return state }
        let gap = lastTimestamp.map { timestamp - $0 } ?? 0
        lastTimestamp = timestamp
        if (!poseReady && (lastReady.map { timestamp - $0 > lossTolerance + 0.000001 } ?? true)) || gap > 0.40 {
            stableSince = nil; countdownSince = nil
            state = .waiting
        }
        guard poseReady else { return state }
        lastReady = timestamp
        if stableSince == nil { stableSince = timestamp }
        if countdownSince == nil {
            guard timestamp - stableSince! >= 0.25 - 0.000001 else { return state }
            countdownSince = timestamp
        }
        let elapsed = timestamp - countdownSince!
        state = elapsed >= 3 - 0.000001 ? .ready : .countdown(max(1, Int(ceil(3 - elapsed))))
        return state
    }
}
