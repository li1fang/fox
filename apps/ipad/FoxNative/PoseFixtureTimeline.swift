import Foundation

// Only generated UI fixtures use this timeline. Live/replayed capture PTS and host clocks are untouched.
struct PoseFixtureTimeline {
    static let frameInterval: TimeInterval = 0.1
    private var origin: TimeInterval?
    private var sampleIndex = 0

    mutating func next(receivedAt: TimeInterval) -> TimeInterval {
        let origin = origin ?? receivedAt
        self.origin = origin
        let timestamp = origin + Double(sampleIndex) * Self.frameInterval
        sampleIndex += 1
        return timestamp
    }
}
