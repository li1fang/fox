import Foundation

enum CaptureLabAccess {
    case pad, phone, other
    var allowsCapture: Bool { self == .pad }
    var allowsLibrary: Bool { true }
    var title: String { allowsCapture ? "采集与视觉实验" : "已保存实验" }
}

// Discovery presentation only; no Bluetooth objects cross the page boundary.
struct FreeCapturePumpDevice: Identifiable, Equatable {
    var id: UUID
    var name: String
    var alias: String?
    var state = "未连接"
    var canReconnect = false
}

// Presentation/runtime types only. The persisted lab package belongs to the shared data contract.
enum FreeCaptureAnalysis: String, CaseIterable, Identifiable {
    case twoD, comparison, none
    var id: Self { self }
    var label: String {
        switch self { case .twoD: return "2D"; case .comparison: return "2D + 3D 对照"; case .none: return "不分析" }
    }
}

struct FreeCaptureOptions: Equatable {
    var frontCamera = true
    var analysis = FreeCaptureAnalysis.twoD
    var pumpEnabled = false
}

struct FreeCapturePackageSummary: Identifiable, Equatable {
    var id: UUID
    var folder: URL
    var recordedAt: Date
    var videoAvailable: Bool
    var recordingState: String
    var encodedFrames: Int?
    var droppedFrames: Int?
    var synthetic = false
    var stopReason: String? = nil
    var frameSummary: String {
        guard let encodedFrames, let droppedFrames else { return "帧数未完整统计" }
        return "\(encodedFrames) 帧已编码 · \(droppedFrames) 帧未编码"
    }
    var videoStatus: String {
        guard videoAvailable else { return "故障资料已保存 · 无完整视频" }
        return recordingState == "interrupted" ? "本段中断 · 视频与实验资料已保存" : "视频与实验资料已保存"
    }
    var stopDescription: String? {
        switch stopReason {
        case "userStopped", nil: return nil
        case "durationLimit": return "已达到单段录制时长上限"
        case "sizeLimit": return "已达到单段文件大小上限"
        case "background": return "进入后台，本段已停止"
        case "viewClosed": return "离开采集页面，本段已停止"
        case "lowSpace": return "可用空间不足，本段已停止"
        case "cameraPermissionDenied", "cameraPermissionRestricted": return "相机权限不可用"
        case "cameraDiscontinuity", "frameGeometryChanged", "clockDiscontinuity": return "采集来源、画面或时钟变化，本段已停止"
        case "processEnded": return "进程中断，已保留可恢复资料"
        default: return "采集异常，本次资料已保留供核对"
        }
    }
}

