import AVFoundation
import Foundation
import FoxTrainingCore
import PumpCore
import Vision
#if canImport(FoxVision3D)
import FoxVision3D
#endif

@MainActor
final class FreeCaptureNativeBackend: FreeCaptureBackend {
    var onEvent: ((FreeCaptureEvent) -> Void)?
    let camera = PoseCamera()
    let root: URL
    private var recording: FreeCaptureRecording?
    private var deadline: Timer?
    private var fixtureTimer: Timer?
    private var capacityTimer: Timer?
    private var fixtureIndex = 0
    private var refreshGeneration = 0
    private var refreshing = false
    private var refreshAgain = false
    private var setupError: String?
    let pump: PumpCaptureRuntime
    private let fixtureOverride: String?
    private var fixture: String? {
        fixtureOverride ?? (ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1" ? ProcessInfo.processInfo.environment["FOX_FREE_CAPTURE_FIXTURE"] : nil)
    }
    var previewSession: AVCaptureSession? { fixture == nil ? camera.session : nil }
    var sourceLabel: String { fixture == nil ? "本机相机 · 无声录像" : "合成测试样本 · 非真实相机" }
    init(root: URL = FreeCaptureArchive.root, fixture: String? = nil, pump: PumpCaptureRuntime? = nil) {
        self.root = root; fixtureOverride = fixture; self.pump = pump ?? PumpCaptureRuntime()
        self.pump.onDevices = { [weak self] devices, status in self?.onEvent?(.pumpDevices(devices, status)) }
        self.pump.onBusy = { [weak self] busy in self?.onEvent?(.pumpControlBusy(busy)) }
        if root == FreeCaptureArchive.root, ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1",
           ProcessInfo.processInfo.environment["FOX_FREE_CAPTURE_FIXTURE"] != nil,
           ProcessInfo.processInfo.arguments.contains("--ui-testing-reset"), FileManager.default.fileExists(atPath: root.path) {
            // Only the explicitly named synthetic UI container is reset, never production originals.
            do { try FileManager.default.removeItem(at: root) }
            catch { setupError = "测试资料未能重置：\(error.localizedDescription)" }
        }
    }

    func start(id: UUID, options: FreeCaptureOptions) throws {
        if let setupError { throw VisionDiagnosticArchive.error(setupError) }
        guard recording == nil else { throw VisionDiagnosticArchive.error("上次采集尚未封存。") }
        guard !pump.isBusy else { throw VisionDiagnosticArchive.error("PUMP写入尚未排空，请等待回调或重新连接后录制。") }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let info = try FileManager.default.attributesOfFileSystem(forPath: documents.path)
        guard (info[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 >= 512 * 1024 * 1024 else {
            throw VisionDiagnosticArchive.error("可用空间不足 512 MiB，未开始采集。")
        }
        let usePump = options.pumpEnabled && (fixture == nil || pump.isSynthetic)
        let controlContext = usePump ? pump.begin(id: id, notification: { [weak self] value in
            guard let self, let run = self.recording else { return }; self.camera.onCaptureQueue { run.pump(value) }
        }, connection: { [weak self] value in
            guard let self, let run = self.recording else { return }; self.camera.onCaptureQueue { run.pump(value) }
        }) : nil
        if usePump && controlContext == nil { throw VisionDiagnosticArchive.error(pump.error ?? "未能关联PUMP会话，未开始录像。") }
        let archive: FreeCaptureArchive
        do {
            archive = try FreeCaptureArchive(id: id, options: options, root: root, synthetic: fixture != nil,
                pumpAliases: usePump ? pump.selectedAliases : [], pumpControlContext: controlContext)
        } catch { pump.finishCapture(); throw error }
        let run: FreeCaptureRecording
        do {
            run = try FreeCaptureRecording(id: id, options: options, archive: archive, camera: camera, fixture: fixture) { [weak self] event in
                Task { @MainActor in self?.receive(event) }
            }
        } catch { pump.finishCapture(); throw error }
        recording = run
        camera.setPoseAnalysisEnabled(false)
        camera.onRawSample = { [weak run] owner, sample in if owner == id { run?.append(sample) } }
        camera.onRawDrop = { [weak run] owner, pts, reason in if owner == id { run?.dropped(pts: pts, reason: reason) } }
        camera.onRawDiscontinuity = { [weak run] owner in if owner == id { run?.stop(reason: "cameraDiscontinuity") } }
        if usePump {
            for device in pump.session?.selected ?? [] {
                guard let value = pump.connectionEvent(device, captureID: id, timestamp: DispatchTime.now().uptimeNanoseconds) else { continue }
                camera.onCaptureQueue { run.pump(value) }
            }
        }
        camera.onState = { [weak self, weak run] owner, state in
            guard let self, owner == id, self.recording?.id == id else { return }
            self.onEvent?(.camera(id, state.label))
            self.camera.onCaptureQueue { run?.cameraState(state.label) }
            switch state {
            case .running: self.onEvent?(.started(id))
            case .starting, .requestingPermission: break
            default:
                let reason: String
                switch state {
                case .denied: reason = "cameraPermissionDenied"
                case .restricted: reason = "cameraPermissionRestricted"
                case .unavailable: reason = "cameraUnavailable"
                case .failed: reason = "cameraFailure"
                default: reason = "cameraInterrupted"
                }
                self.camera.onCaptureQueue { run?.stop(reason: reason) }
            }
        }
        deadline = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop(id: id, reason: "durationLimit") }
        }
        capacityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let info = try? FileManager.default.attributesOfFileSystem(forPath: documents.path),
                      let bytes = (info[.systemFreeSize] as? NSNumber)?.int64Value else { return }
                if bytes < 512 * 1024 * 1024 { self.stop(id: id, reason: "lowSpace") }
            }
        }
        if fixture != nil {
            fixtureIndex = 0; onEvent?(.camera(id, "合成输入运行中")); onEvent?(.started(id))
            fixtureTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak run] _ in
                Task { @MainActor in
                    guard let self, self.recording?.id == id else { return }
                    let time = 100 + Double(self.fixtureIndex) / 10; self.fixtureIndex += 1
                    self.camera.onCaptureQueue {
                        do { run?.append(try VisionDiagnosticRecorder.syntheticSample(timestamp: time, width: 64, height: 96)) }
                        catch { run?.stop(reason: "fixtureFailure") }
                    }
                }
            }
        } else {
            // Data output applies this rotation. Both analyzers receive .up, once.
            camera.setOrientation(.portrait)
            camera.start(position: options.frontCamera ? .front : .back, id: id)
        }
    }
    func stop(id: UUID, reason: String) {
        guard let run = recording, run.id == id else { return }
        cancelTimers()
        pump.detachNotifications()
        camera.onCaptureQueue { run.stop(reason: reason) }
        camera.stop()
    }
    private func receive(_ event: FreeCaptureEvent) {
        switch event {
        case .finishing(let id) where recording?.id == id:
            cancelTimers(); pump.detachNotifications(); camera.stop()
        case .finished(let package) where recording?.id == package.id:
            cancelTimers(); pump.finishCapture(); camera.stop(); recording = nil
        case .failed(let id, _) where recording?.id == id:
            cancelTimers(); pump.finishCapture(); camera.stop(); recording = nil
        default: break
        }
        onEvent?(event)
    }
    func scanPump() { guard recording == nil else { return }; pump.scan() }
    func stopPumpScan() { pump.stopScan() }
    func selectPump(_ id: UUID) { guard recording == nil else { return }; pump.select(id) }
    func reconnectPump(_ id: UUID) { guard !pump.isApplying else { return }; pump.reconnect(id) }
    func setPumpEnabled(_ enabled: Bool) { pump.setEnabled(enabled) }
    func closePump() { pump.shutdown() }
    private func cancelTimers() {
        deadline?.invalidate(); deadline = nil; fixtureTimer?.invalidate(); fixtureTimer = nil
        capacityTimer?.invalidate(); capacityTimer = nil
    }
    func refresh() {
        if let setupError { onEvent?(.libraryFailure(setupError)); return }
        refreshGeneration += 1
        if refreshing { refreshAgain = true; return }
        refreshing = true; onEvent?(.libraryLoading(true))
        let generation = refreshGeneration
        let root = root
        Task {
            defer {
                refreshing = false; onEvent?(.libraryLoading(false))
                if refreshAgain { refreshAgain = false; refresh() }
            }
            do {
                let result = try await Task.detached(priority: .utility) {
                    let recoveryIssues = try FreeCaptureArchive.recover(root: root)
                    let library = try FreeCaptureArchive.library(root: root)
                    return (library.packages, recoveryIssues + library.issues)
                }.value
                guard generation == refreshGeneration else { return }
                onEvent?(.library(result.0))
                if !result.1.isEmpty { onEvent?(.libraryFailure("部分实验待修复，原件保留：" + result.1.joined(separator: "；"))) }
            } catch {
                guard generation == refreshGeneration else { return }
                onEvent?(.libraryFailure("实验目录未能读取，原件保留：\(error.localizedDescription)"))
            }
        }
    }
    func remove(id: UUID) {
        guard recording == nil else { return }
        let root = root
        Task {
            do {
                try await Task.detached(priority: .utility) { try FreeCaptureArchive.remove(id: id, root: root) }.value
                refresh()
            } catch { onEvent?(.libraryFailure("未删除实验：\(error.localizedDescription)")) }
        }
    }
}

// All mutable recording/archive operations run on PoseCamera's queue. Inference only
// returns immutable rows onto that queue; it never blocks the writer or touches training.
private final class FreeCaptureRecording {
    let id: UUID
    private let options: FreeCaptureOptions
    private let archive: FreeCaptureArchive
    private let camera: PoseCamera
    private let writer: FreeCaptureVideoWriter
    private let gate: FreeCaptureAnalysisGate
    private let analysisQueue = DispatchQueue(label: "fox.free-capture.analysis", qos: .utility)
    private let fixture: String?
    private let emit: (FreeCaptureEvent) -> Void
    private var finishing = false
    private var seq = 0
    private var origin: CMTime?
    private var dimensions: (Int, Int)?
    private var cameraDrops = 0
    #if canImport(FoxVision3D)
    private let threeD = AppleVision3DExtractor()
    #endif
    init(id: UUID, options: FreeCaptureOptions, archive: FreeCaptureArchive, camera: PoseCamera,
         fixture: String?, emit: @escaping (FreeCaptureEvent) -> Void) throws {
        self.id = id; self.options = options; self.archive = archive; self.camera = camera
        self.fixture = fixture; self.emit = emit
        writer = try FreeCaptureVideoWriter(folder: archive.folder); gate = .init(captureID: id)
    }
    func append(_ sample: CMSampleBuffer) {
        guard !finishing else { return }
        let host = DispatchTime.now().uptimeNanoseconds, index = seq
        seq += 1
        do {
            let frame = try writer.append(sample)
            if origin == nil, frame.encoded { origin = frame.capturePTS }
            dimensions = (frame.width, frame.height)
            if let origin { try archive.frame(frame, seq: index, hostNS: host, origin: origin) }
            emit(.progress(id, encoded: writer.encodedFrames, dropped: writer.droppedFrames + cameraDrops))
            guard frame.reason != "outOfOrder" else { return }
            guard options.analysis != .none else { return }
            let admitted = gate.admit(captureID: id, frame: UInt64(index))
            if admitted == .busy {
                let row = poseRow(sample, index: index, host: host, state: "dropped", reason: "analysis_busy", people: [], elapsed: 0)
                try archive.pose(JSONEncoder().encode(row), kind: "pose2d", issue: "analysis_busy_drops")
                #if canImport(FoxVision3D)
                if options.analysis == .comparison {
                    let row = Pose3DFrame(context: context(sample, index: index), requestedRevision: threeD.revision, outcome: .dropped,
                                          failure: .init(domain: "fox.capture.analysis_busy", code: 1))
                    try archive.pose(JSONEncoder().encode(row), kind: "pose3d", issue: "analysis_busy_drops")
                }
                #endif
                return
            }
            guard admitted == .accepted else { return }
            analysisQueue.async { [self] in
                var result = Analysis()
                let deliver = gate.perform(captureID: id, frame: UInt64(index), first: {
                    result = analyze2D(sample, index: index, host: host)
                }, then: {
                    append3D(sample, index: index, to: &result)
                })
                camera.onCaptureQueue { [self] in
                    let current = gate.complete(captureID: id, frame: UInt64(index))
                    guard !finishing, deliver, current else { return }
                    do {
                        for item in result.rows { try archive.pose(item.bytes, kind: item.kind, issue: item.issue) }
                        if let unavailable = result.unavailable3D { archive.noteAnalysisIssue("pose3d", reason: unavailable) }
                        emit(.analysis(id, result.status))
                    } catch { stop(reason: "logFailure") }
                }
            }
        } catch {
            stop(reason: (error as? FreeCaptureVideoWriter.Stop)?.rawValue ?? "writerFailure")
        }
    }
    func dropped(pts: CMTime, reason: String) {
        guard !finishing else { return }
        cameraDrops += 1
        let index = seq; seq += 1
        do {
            if pts.isNumeric, let origin, let dimensions {
                try archive.frame(.init(capturePTS: pts, videoTime: CMTimeSubtract(pts, origin), encoded: false,
                    reason: reason, width: dimensions.0, height: dimensions.1), seq: index,
                    hostNS: DispatchTime.now().uptimeNanoseconds, origin: origin)
            } else { try archive.event("camera_frame_dropped", reason: reason) }
        } catch { stop(reason: "logFailure") }
    }
    func pump(_ value: PumpNotificationEvent) {
        guard !finishing, value.captureID == id.uuidString else { return }
        guard archive.acceptsPump(captureID: value.captureID, clockID: value.hostClockID, alias: value.deviceAlias) else {
            emit(.sensor(id, "PUMP 来源不匹配 · 录像继续")); return
        }
        do { try archive.pump(value); emit(.sensor(id, "\(value.deviceAlias) 正在接收遥测 · 单位待核对")) } catch { stop(reason: "sensorLogFailure") }
    }
    func cameraState(_ value: String) {
        guard !finishing else { return }
        do { try archive.event("camera_state", reason: value) } catch { stop(reason: "logFailure") }
    }
    func pump(_ value: PumpConnectionEvent) {
        guard !finishing, value.captureID == id.uuidString else { return }
        guard archive.acceptsPump(captureID: value.captureID, clockID: value.hostClockID, alias: value.deviceAlias) else {
            emit(.sensor(id, "PUMP 来源不匹配 · 录像继续")); return
        }
        do { try archive.pump(value); emit(.sensor(id, "\(value.deviceAlias) \(value.state) · 录像继续")) } catch { stop(reason: "sensorLogFailure") }
    }
    func stop(reason: String) {
        guard !finishing else { return }
        finishing = true
        emit(.finishing(id))
        if gate.close() {
            archive.noteAnalysisIssue("pose2d", reason: "pending_at_capture_stop")
            if options.analysis == .comparison { archive.noteAnalysisIssue("pose3d", reason: "pending_at_capture_stop") }
        }
        let encoded = writer.encodedFrames, dropped = writer.droppedFrames + cameraDrops
        writer.finish { [self] result in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    var summary: FreeCaptureVideoWriter.Summary?
                    var error: String?
                    switch result {
                    case .success(let value): summary = value
                    case .failure(let failure): error = failure.localizedDescription
                    }
                    summary?.droppedFrames += cameraDrops
                    let package = try archive.seal(video: summary, reason: reason, videoError: error, encodedFrames: encoded, droppedFrames: dropped)
                    emit(.finished(package))
                } catch { emit(.failed(id, "封存未完成，文件仍保留：\(error.localizedDescription)")) }
            }
        }
    }
    private struct Analysis {
        var rows: [(kind: String, bytes: Data, issue: String?)] = []
        var status = "未检测到人体"
        var unavailable3D: String?
    }
    private func analyze2D(_ sample: CMSampleBuffer, index: Int, host: UInt64) -> Analysis {
        var result = Analysis()
        let began = DispatchTime.now().uptimeNanoseconds
        let twoD: LabPose2DFrame
        do {
            if fixture == "analysis_error" { throw NSError(domain: "fox.synthetic_analysis", code: 1) }
            // Synthetic outcomes must not initialize a real Vision request.
            var observations: [VNHumanBodyPoseObservation] = []
            if fixture == nil {
                let request = VNDetectHumanBodyPoseRequest()
                try VNImageRequestHandler(cmSampleBuffer: sample, orientation: .up).perform([request])
                observations = request.results ?? []
            }
            var people: [[LabPose2DFrame.Joint]] = []
            for observation in observations {
                let points = try observation.recognizedPoints(.all).filter { $0.value.confidence > 0 }
                let joints = PoseCamera.joints.compactMap { name, key -> LabPose2DFrame.Joint? in
                    guard let point = points[key] else { return nil }
                    return LabPose2DFrame.Joint(name: name.rawValue, x: point.location.x, y: point.location.y,
                                               confidence: Double(point.confidence))
                }
                if !joints.isEmpty { people.append(joints) }
            }
            twoD = poseRow(sample, index: index, host: host, state: people.isEmpty ? "no_observation" : "observed",
                           reason: nil, people: people, elapsed: DispatchTime.now().uptimeNanoseconds - began)
            result.status = people.isEmpty ? "2D 未检测到人体 · 录像继续" : "2D 已取得观测 · 未评测次数"
        } catch {
            let failure = error as NSError
            twoD = poseRow(sample, index: index, host: host, state: "request_failed", reason: "\(failure.domain):\(failure.code)",
                           people: [], elapsed: DispatchTime.now().uptimeNanoseconds - began)
            result.status = "2D 分析失败 · 录像继续"
        }
        do {
            try twoD.validate()
            result.rows.append(("pose2d", try JSONEncoder().encode(twoD), twoD.state == "request_failed" ? "request_failed" : nil))
        } catch {
            result.status = "2D 输出无效 · 录像继续"
            let failure = poseRow(sample, index: index, host: host, state: "request_failed", reason: "invalid_output", people: [], elapsed: DispatchTime.now().uptimeNanoseconds - began)
            if let bytes = try? JSONEncoder().encode(failure) { result.rows.append(("pose2d", bytes, "invalid_output")) }
        }
        return result
    }
    private func append3D(_ sample: CMSampleBuffer, index: Int, to result: inout Analysis) {
        if options.analysis == .comparison {
            #if canImport(FoxVision3D)
            let observation: Pose3DFrame
            if fixture == "3d_unavailable" {
                observation = .init(context: context(sample, index: index), requestedRevision: threeD.revision, outcome: .unsupported,
                                    failure: .init(domain: "fox.synthetic_3d_unavailable", code: 1))
            } else { observation = threeD.extract(sample, orientation: .up, context: context(sample, index: index)) }
            do {
                try observation.validate()
                result.rows.append(("pose3d", try JSONEncoder().encode(observation),
                                    [.observed, .noObservation].contains(observation.outcome) ? nil : observation.outcome.rawValue))
                result.status += "；3D：\(observation.outcome.rawValue)"
            } catch { result.unavailable3D = "invalid_output"; result.status += "；3D 输出无效" }
            #else
            result.unavailable3D = "module_unavailable"; result.status += "；3D 模块未接入"
            #endif
        }
    }
    private func poseRow(_ sample: CMSampleBuffer, index: Int, host: UInt64, state: String, reason: String?,
                         people: [[LabPose2DFrame.Joint]], elapsed: UInt64) -> LabPose2DFrame {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample), pixels = CMSampleBufferGetImageBuffer(sample)
        return .init(captureID: id.uuidString, sourceID: archive.sourceID, seq: index,
            pts: .init(value: String(pts.value), timescale: pts.timescale, epoch: String(pts.epoch)), hostReceivedNS: String(host),
            width: pixels.map(CVPixelBufferGetWidth) ?? 0, height: pixels.map(CVPixelBufferGetHeight) ?? 0,
            requestRevision: fixture == nil ? VNDetectHumanBodyPoseRequest.currentRevision : 1,
            state: state, reason: reason, people: people, inferenceNS: String(elapsed))
    }
    #if canImport(FoxVision3D)
    private func context(_ sample: CMSampleBuffer, index: Int) -> Pose3DFrameContext {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample), pixels = CMSampleBufferGetImageBuffer(sample)
        return .init(streamID: archive.sourceID, segmentID: id.uuidString, frameIndex: index,
            pts: .init(value: pts.value, timescale: pts.timescale, epoch: pts.epoch),
            width: pixels.map(CVPixelBufferGetWidth) ?? 0, height: pixels.map(CVPixelBufferGetHeight) ?? 0, orientation: 1, sourceMirrored: false)
    }
    #endif
}
