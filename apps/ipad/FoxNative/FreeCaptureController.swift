import Foundation
import Combine

enum FreeCaptureEvent {
    case started(UUID)
    case finishing(UUID)
    case camera(UUID, String)
    case progress(UUID, encoded: Int, dropped: Int)
    case analysis(UUID, String)
    case sensor(UUID, String)
    case finished(FreeCapturePackageSummary)
    case failed(UUID, String)
    case library([FreeCapturePackageSummary])
    case libraryFailure(String)
    case libraryLoading(Bool)
    case pumpDevices([FreeCapturePumpDevice], String)
}

@MainActor
protocol FreeCaptureBackend: AnyObject {
    var onEvent: ((FreeCaptureEvent) -> Void)? { get set }
    var sourceLabel: String { get }
    func start(id: UUID, options: FreeCaptureOptions) throws
    func stop(id: UUID, reason: String)
    func refresh()
    func remove(id: UUID)
    func scanPump()
    func stopPumpScan()
    func selectPump(_ id: UUID)
    func reconnectPump(_ id: UUID)
}
extension FreeCaptureBackend {
    var sourceLabel: String { "本机相机 · 无声录像" }
    func scanPump() {}
    func stopPumpScan() {}
    func selectPump(_ id: UUID) {}
    func reconnectPump(_ id: UUID) {}
}

@MainActor
final class FreeCaptureController: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, finishing, finished, failed }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var captureID: UUID?
    @Published private(set) var options = FreeCaptureOptions()
    @Published private(set) var encodedFrames = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var analysisStatus = "尚未开始"
    @Published private(set) var sensorStatus = "PUMP 未启用"
    @Published private(set) var cameraStatus = "尚未启动"
    @Published private(set) var packages: [FreeCapturePackageSummary] = []
    @Published private(set) var latest: FreeCapturePackageSummary?
    @Published private(set) var error: String?
    @Published private(set) var exportStatus: String?
    @Published private(set) var recordingSince: Date?
    @Published private(set) var pumpDevices: [FreeCapturePumpDevice] = []
    @Published private(set) var pumpDiscoveryStatus = "尚未扫描"
    @Published private(set) var libraryLoading = false
    private let backend: FreeCaptureBackend

    init(backend: FreeCaptureBackend) {
        self.backend = backend
        backend.onEvent = { [weak self] in self?.receive($0) }
        backend.refresh()
    }
    var sourceLabel: String { backend.sourceLabel }
    var selectionLocked: Bool {
        switch phase {
        case .starting, .recording, .finishing: return true
        case .idle, .finished, .failed: return false
        }
    }
    var evaluationStatus: String { "未评测" }
    var frameStatus: String {
        phase == .finished ? (latest?.frameSummary ?? "帧数未完整统计") : "\(encodedFrames) 帧已编码 · \(droppedFrames) 帧未编码"
    }
    var status: String {
        switch phase {
        case .idle: return "尚未录制"
        case .starting: return "正在启动录像"
        case .recording: return "录像中"
        case .finishing: return "正在封存，请稍候"
        case .finished:
            if latest?.videoAvailable != true { return "故障资料已保存 · 无完整视频" }
            return latest?.recordingState == "interrupted" ? "本段中断 · 原件已保存" : "已保存实验原件"
        case .failed: return "采集未能完成，请检查错误"
        }
    }
    func changeCamera(front: Bool) { guard !selectionLocked else { return }; options.frontCamera = front }
    func changeAnalysis(_ mode: FreeCaptureAnalysis) { guard !selectionLocked else { return }; options.analysis = mode }
    func changePump(enabled: Bool) { guard !selectionLocked else { return }; options.pumpEnabled = enabled }
    func scanPump() { guard !selectionLocked else { return }; backend.scanPump() }
    func stopPumpScan() { backend.stopPumpScan() }
    func selectPump(_ id: UUID) { guard !selectionLocked else { return }; backend.selectPump(id) }
    func reconnectPump(_ id: UUID) { guard phase == .recording else { return }; backend.reconnectPump(id) }
    func start() {
        guard !selectionLocked else { return }
        let id = UUID()
        captureID = id; phase = .starting; latest = nil; error = nil; exportStatus = nil
        encodedFrames = 0; droppedFrames = 0; recordingSince = nil
        cameraStatus = "等待相机启动"
        analysisStatus = options.analysis == .none ? "未启用分析" : "等待画面"
        sensorStatus = options.pumpEnabled ? "等待 PUMP 状态" : "PUMP 未启用"
        do { try backend.start(id: id, options: options) }
        catch { receive(.failed(id, error.localizedDescription)) }
    }
    func stop(reason: String) {
        guard let id = captureID, phase == .starting || phase == .recording else { return }
        phase = .finishing
        recordingSince = nil
        backend.stop(id: id, reason: reason)
    }
    func refresh() { backend.refresh() }
    func remove(_ package: FreeCapturePackageSummary) {
        guard !selectionLocked, !libraryLoading, packages.contains(where: { $0.id == package.id }) else { return }
        backend.remove(id: package.id)
    }
    func exportURL(for package: FreeCapturePackageSummary) -> URL? {
        guard !selectionLocked, !libraryLoading, packages.contains(package) else { return nil }
        return package.folder
    }
    func exportFinished(success: Bool) {
        exportStatus = success ? "已导出副本，本机原件保留。" : "已关闭导出面板，本机原件保留。"
    }
    private func receive(_ event: FreeCaptureEvent) {
        if case .library(let values) = event {
            packages = values.sorted { $0.recordedAt > $1.recordedAt }
            return
        }
        if case .libraryFailure(let message) = event { error = message; return }
        if case .libraryLoading(let value) = event { libraryLoading = value; return }
        if case .pumpDevices(let devices, let status) = event { pumpDevices = devices; pumpDiscoveryStatus = status; return }
        switch event {
        case .started(let id) where captureID == id && phase == .starting:
            phase = .recording; recordingSince = Date()
        case .finishing(let id) where captureID == id:
            phase = .finishing; recordingSince = nil
        case .camera(let id, let value) where captureID == id && selectionLocked:
            cameraStatus = value
        case .progress(let id, let encoded, let dropped) where captureID == id && selectionLocked:
            encodedFrames = encoded; droppedFrames = dropped
        case .analysis(let id, let value) where captureID == id && selectionLocked:
            analysisStatus = value
        case .sensor(let id, let value) where captureID == id && selectionLocked:
            sensorStatus = value
        case .finished(let package) where captureID == package.id:
            latest = package; encodedFrames = package.encodedFrames ?? 0; droppedFrames = package.droppedFrames ?? 0
            if package.videoAvailable { cameraStatus = "输入已停止" }
            captureID = nil; recordingSince = nil; phase = .finished; backend.refresh()
        case .failed(let id, let message) where captureID == id:
            error = message; captureID = nil; recordingSince = nil; phase = .failed; backend.refresh()
            cameraStatus = "输入已停止"
        default: break
        }
    }
}
