import Foundation

/// One pure clock projection for the existing non-visual display, camera overlay and speech.
/// It describes a plan, never measured motion or an automatically completed repetition.
public struct TempoSample: Equatable {
    public var phase: String
    public var phaseIndex: Int
    public var cycle: Int
    public var progress: Double
    public var scale: Double
    public var isValid: Bool
    public var label: String {
        switch phase {
        case "lift": return "抬起"
        case "lower": return "放下"
        case "peak": return "停留"
        case "contract": return "轻轻收缩"
        case "relax": return "完全放松"
        default: return "保持"
        }
    }
    static let unavailable = TempoSample(phase: "hold", phaseIndex: 0, cycle: 0, progress: 0, scale: 1, isValid: false)
}

public enum TempoTimeline {
    public static func sample(_ tempo: [TempoPhase], elapsed: Double) -> TempoSample {
        guard elapsed.isFinite, elapsed >= 0, !tempo.isEmpty,
              tempo.allSatisfy({ $0.seconds.isFinite && $0.seconds > 0 }) else { return .unavailable }
        let total = tempo.reduce(0) { $0 + $1.seconds }
        guard total.isFinite, total > 0, elapsed / total < Double(Int.max) else { return .unavailable }
        var remaining = elapsed.truncatingRemainder(dividingBy: total)
        for (index, item) in tempo.enumerated() {
            if remaining < item.seconds {
                let progress = remaining / max(0.1, item.seconds)
                let scale: Double
                switch item.phase {
                case "lift", "contract": scale = 0.65 + progress * 0.35
                case "lower", "relax": scale = 1 - progress * 0.35
                case "peak": scale = 1 + sin(progress * .pi * 8) * 0.025
                default: scale = 1
                }
                return TempoSample(phase: item.phase, phaseIndex: index, cycle: Int(elapsed / total),
                    progress: progress, scale: scale, isValid: true)
            }
            remaining -= item.seconds
        }
        return .unavailable
    }
}
