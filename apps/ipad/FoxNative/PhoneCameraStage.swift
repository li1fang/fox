import FoxTrainingCore
import SwiftUI

struct PhoneCameraStage: View {
    @ObservedObject var controller: VisionLabController
    var idleLabel: String? = nil
    var guidance: GuidanceSession? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            PosePreview(controller: controller)
            if let guidance, let frame = controller.latest?.frame {
                GuidanceCameraOverlay(output: guidance.output, imageSize: CGSize(width: frame.width, height: frame.height), active: controller.isCounting)
            }
            if case .countdown(let seconds) = controller.startState {
                Text("\(seconds)").font(.system(size: 72, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white).padding(16).background(.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("vision-countdown")
            }
            if controller.cameraState != .running {
                VStack(spacing: 12) {
                    Text(controller.cameraState == .stopped ? (idleLabel ?? controller.cameraState.label) : controller.cameraState.label)
                        .font(.headline).multilineTextAlignment(.center)
                    if controller.cameraState == .denied || controller.cameraState == .restricted {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: { Label("打开设置", systemImage: "gearshape").frame(minHeight: 44) }
                            .accessibilityIdentifier("vision-open-settings")
                    } else if controller.cameraState != .requestingPermission && controller.cameraState != .starting && !(controller.cameraState == .stopped && idleLabel != nil) {
                        Button { controller.retryCamera() } label: {
                            Label("重试相机", systemImage: "arrow.clockwise").frame(minHeight: 44)
                        }.accessibilityIdentifier("vision-retry-camera")
                    }
                }.foregroundStyle(.white).padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
