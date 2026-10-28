import FoxTrainingCore

// Product choices are not the vision algorithm's supported-exercise enum.
enum TrainingActivity: String, CaseIterable, Identifiable {
    case curl, lateralRaise, latPulldown, kegel
    var id: String { rawValue }
    var vision: VisionExercise? { VisionExercise(rawValue: rawValue) }
    var label: String { vision?.label ?? "凯格尔运动" }
    var exerciseID: String {
        switch self {
        case .curl: return "dumbbell_curl"
        case .lateralRaise: return "lateral_raise"
        case .latPulldown: return "lat_pulldown"
        case .kegel: return "kegel"
        }
    }
    var subtitle: String {
        switch self {
        case .curl: return "侧身 · 单侧试练"
        case .lateralRaise: return "正面 · 相机辅助"
        case .latPulldown: return "背面 · 相机辅助"
        case .kegel: return "节奏引导 · 不使用相机"
        }
    }
    init?(exerciseID: String) {
        guard let value = Self.allCases.first(where: { $0.exerciseID == exerciseID }) else { return nil }
        self = value
    }
}
