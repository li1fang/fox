import FoxTrainingCore
import SwiftUI

enum GuidanceOverlayGeometry {
    static func imageRect(image: CGSize, viewport: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2, y: (viewport.height - size.height) / 2, width: size.width, height: size.height)
    }
}

struct GuidanceCameraOverlay: View {
    @ObservedObject var output: GuidanceOutputController
    let imageSize: CGSize
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if output.overlayEnabled && active {
                let rect = GuidanceOverlayGeometry.imageRect(image: imageSize, viewport: geometry.size)
                let side = min(rect.width, rect.height) * 0.38
                let state = output.presentation
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(state.isMoving ? Color.green.opacity(0.22) : Color.white.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.8), lineWidth: 2))
                        .frame(width: side, height: side)
                        .scaleEffect(reduceMotion ? 0.8 : state.scale)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: state.scale)
                    Text(state.source == .planned ? "计划 · \(state.label)" : state.label)
                        .font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .padding(4).background(.black.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 4))
                }.position(x: rect.midX, y: rect.midY)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("guidance-camera-overlay")
            }
        }.allowsHitTesting(false)
    }
}

struct GuidanceControls: View {
    @ObservedObject var session: GuidanceSession
    @ObservedObject private var output: GuidanceOutputController
    var allowsPlannedMode: Bool
    init(session: GuidanceSession, allowsPlannedMode: Bool = false) {
        self.session = session; output = session.output; self.allowsPlannedMode = allowsPlannedMode
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { output.speechEnabled }, set: { session.setSpeech($0) })) {
                Label("语音引导", systemImage: output.speechEnabled ? "speaker.wave.2" : "speaker.slash")
            }.accessibilityIdentifier("guidance-speech-toggle")
            Toggle(isOn: Binding(get: { output.overlayEnabled }, set: { session.setOverlay($0) })) {
                Label("节奏叠加", systemImage: "square.on.square")
            }.accessibilityIdentifier("guidance-overlay-toggle")
            Picker("引导来源", selection: Binding(get: { session.effectiveMode }, set: { session.setMode($0) })) {
                if session.usesVision { Text("观察跟随").tag(GuidanceMode.observed) }
                if allowsPlannedMode { Text("计划节奏").tag(GuidanceMode.planned) }
                Text("关闭").tag(GuidanceMode.off)
            }.pickerStyle(.segmented).accessibilityIdentifier("guidance-mode")
            if let error = output.error { Text(error).font(.callout).foregroundStyle(FoxStyle.coral) }
        }
    }
}

struct GuidanceMuteButton: View {
    let session: GuidanceSession
    @ObservedObject private var output: GuidanceOutputController
    init(session: GuidanceSession) { self.session = session; output = session.output }
    var body: some View {
        Button { session.setSpeech(!output.speechEnabled) } label: {
            Image(systemName: output.speechEnabled ? "speaker.wave.2" : "speaker.slash")
                .font(.title3).frame(width: 44, height: 44).foregroundStyle(.white)
                .background(.black.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel(output.speechEnabled ? "关闭语音引导" : "开启语音引导")
            .accessibilityIdentifier("guidance-quick-mute").help("切换语音引导")
    }
}
