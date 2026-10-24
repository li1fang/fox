import SwiftUI
import FoxTrainingCore

struct TempoDisplay: View {
    let tempo: [TempoPhase]
    let elapsed: Double
    let running: Bool
    var compact = false
    var drawingSize: CGFloat = 160
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phase = TempoTimeline.sample(tempo, elapsed: elapsed)
        let scale = running && !reduceMotion ? phase.scale : 0.8
        VStack(spacing: compact ? 6 : 16) {
            RoundedRectangle(cornerRadius: 8)
                .fill(phase.phase == "peak" ? FoxStyle.coral : FoxStyle.green)
                .frame(width: compact ? 50 : drawingSize, height: compact ? 50 : drawingSize).scaleEffect(scale)
            Text(running ? phase.label : "待开始").font(.system(size: compact ? 16 : 22, weight: .semibold))
                .accessibilityIdentifier("tempo-phase")
        }
    }
}
