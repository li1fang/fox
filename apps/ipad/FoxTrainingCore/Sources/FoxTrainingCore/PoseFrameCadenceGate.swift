/// Camera admission only: preserve source PTS and the existing greedy 12Hz policy.
/// Source changes explicitly reset this clock; arbitrary backward frames never do.
public struct PoseFrameCadenceGate {
    private var lastProcessed: Double?
    public init() {}
    public mutating func accepts(_ pts: Double) -> Bool {
        guard pts.isFinite, lastProcessed.map({pts-$0 >= 1.0/12}) ?? true else {return false}
        lastProcessed=pts;return true
    }
    public mutating func resetSourceClock() {lastProcessed=nil}
}
