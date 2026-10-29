import SwiftUI

/// The legacy assessment controller remains the owner of exercise evaluation only.
struct CaptureLabView: View {
    @ObservedObject var controller: VisionLabController
    @StateObject private var freeCapture: FreeCaptureController
    var phoneLandscapeNavigation: AnyView?
    @State private var free = false
    init(controller: VisionLabController, phoneLandscapeNavigation: AnyView? = nil, initialFree: Bool = false) {
        self.controller = controller; self.phoneLandscapeNavigation = phoneLandscapeNavigation
        _freeCapture = StateObject(wrappedValue: FreeCaptureController(backend: FreeCaptureNativeBackend()))
        _free = State(initialValue: initialFree)
    }
    private var modeLocked: Bool {
        freeCapture.selectionLocked || controller.isCounting || controller.isPreparing ||
            controller.diagnosticCapture.isActive || controller.diagnosticCapture.finishing
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("实验方式", selection: $free) {
                Text("动作评测").tag(false); Text("自由采集").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                .disabled(modeLocked).accessibilityIdentifier("capture-lab-mode")
            if free { FreeCaptureView(controller: freeCapture, phoneLandscapeNavigation: phoneLandscapeNavigation) }
            else { VisionLabView(controller: controller, phoneLandscapeNavigation: phoneLandscapeNavigation) }
        }
    }
}

/// A standalone destination: entering capture never constructs or transitions a TrainingStore.
@MainActor
struct CaptureLabDestination: View {
    @StateObject private var vision = VisionLabController()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CaptureLabView(controller: vision, initialFree: true)
                .navigationTitle("采集与视觉实验").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("capture-lab-close")
                } }
        }
    }
}
