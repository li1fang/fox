import Foundation

// Only generated UI fixtures use this timeline. Live/replayed capture PTS and host clocks are untouched.
struct PoseFixtureTimeline {
    static let frameInterval: TimeInterval = 0.1
    private var origin: TimeInterval?
    private var sampleIndex = 0
    private(set) var generation = 0

    mutating func controlBoundary(receivedAt: TimeInterval) {
        // No generated timeline exists on live or numeric/video replay paths.
        guard origin != nil, receivedAt.isFinite, receivedAt >= 0 else { return }
        origin = receivedAt
        sampleIndex = 1
        generation += 1
    }

    mutating func samplesDue(receivedAt: TimeInterval) -> [TimeInterval] {
        guard receivedAt.isFinite, receivedAt >= 0 else { return [] }
        guard let origin else { return [next(receivedAt: receivedAt)] }
        guard receivedAt >= origin else { return [] }
        // Timer callbacks can coalesce. Deliver the known sequence, not one slower sample per callback.
        // The small rounding allowance only compensates subtraction of large uptime values.
        let due = floor((receivedAt - origin) / Self.frameInterval + 0.00000001) + 1 - Double(sampleIndex)
        let count = Int(min(50, max(0, due)))
        return (0..<count).map { _ in next(receivedAt: receivedAt) }
    }

    mutating func next(receivedAt: TimeInterval) -> TimeInterval {
        let origin = origin ?? receivedAt
        self.origin = origin
        let timestamp = origin + Double(sampleIndex) * Self.frameInterval
        sampleIndex += 1
        return timestamp
    }
}
