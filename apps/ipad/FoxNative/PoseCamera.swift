import AVFoundation
import FoxTrainingCore
import ImageIO
import UIKit
import Vision

struct CameraSourceContinuity {
    private var previous: String?
    mutating func changed(to id: String) -> Bool {
        defer { previous = id }
        return previous != nil && previous != id
    }
}

enum PoseCameraState: Equatable {
    case stopped, requestingPermission, starting, running, denied, restricted, unavailable, interrupted
    case failed(String)
    var label: String {
        switch self {
        case .stopped: return "相机已停止"
        case .requestingPermission: return "等待相机权限"
        case .starting: return "相机启动中"
        case .running: return "相机运行中"
        case .denied: return "相机权限未开启"
        case .restricted: return "相机访问受限"
        case .unavailable: return "相机不可用"
        case .interrupted: return "相机已中断"
        case .failed(let message): return "识别失败：\(message)"
        }
    }
}

struct CapturedPose {
    let frame: PoseFrame
    let latencyMs: Double
    let revision: Int
    var cameraGeometry: VisionCameraGeometry? = nil
}

final class PoseCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onFrame: ((UUID, CapturedPose) -> Void)?
    var onState: ((UUID, PoseCameraState) -> Void)?
    var onDiscontinuity: ((UUID) -> Void)?
    var onDiagnosticResult: ((UUID, Result<VisionDiagnosticManifest, Error>) -> Void)?
    private var diagnosticRecorder: VisionDiagnosticRecorder?
    private let queue = DispatchQueue(label: "fox.pose.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let request = VNDetectHumanBodyPoseRequest()
    private var runID: UUID?
    private var activeDevice: AVCaptureDevice?
    private var sourceContinuity = CameraSourceContinuity()
    private var lastProcessed = -Double.infinity
    private var orientation: AVCaptureVideoOrientation = .portrait
    private var observers: [NSObjectProtocol] = []

    func beginDiagnostic(context: VisionDiagnosticContext, root: URL) {
        queue.async { [self] in
            do {
                guard self.diagnosticRecorder == nil else { throw VisionDiagnosticArchive.error("已有录像正在进行。") }
                let handler = self.onDiagnosticResult
                self.diagnosticRecorder = try VisionDiagnosticRecorder(context: context, root: root) { [weak self] result in
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        if self.diagnosticRecorder?.context.id == context.id { self.diagnosticRecorder = nil }
                    }
                    DispatchQueue.main.async { handler?(context.id, result) }
                }
            } catch { DispatchQueue.main.async { self.onDiagnosticResult?(context.id, .failure(error)) } }
        }
    }
    func endDiagnostic(reason: String) {
        queue.async { [self] in finishDiagnostic(reason: reason) }
    }
    private func finishDiagnostic(reason: String) {
        let recorder = diagnosticRecorder; diagnosticRecorder = nil
        recorder?.finish(reason: reason)
    }
    func diagnosticEvent(_ event: VisionDiagnosticEvent) {
        queue.async { [weak self] in self?.diagnosticRecorder?.event(event) }
    }
    func diagnosticPose(_ pose: VisionDiagnosticPose) {
        queue.async { [weak self] in self?.diagnosticRecorder?.appendPose(pose) }
    }
    func diagnosticFixtureFrame(_ frame: PoseFrame) {
        queue.async { [weak self] in
            guard let self, self.diagnosticRecorder != nil else { return }
            do {
                let sample = try VisionDiagnosticRecorder.syntheticSample(timestamp: frame.timestamp,
                    width: Int(frame.width), height: Int(frame.height))
                if let reason = self.diagnosticRecorder?.append(sample) { self.finishDiagnostic(reason: reason) }
            } catch { self.finishDiagnostic(reason: "fixtureFailure") }
        }
    }

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, let id = self.runID else { return }
                self.emit(.interrupted, id: id)
                self.breakContinuity(id: id)
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "视频采集不可用"
            self?.queue.async { [weak self] in
                guard let self, let id = self.runID else { return }
                self.emit(.failed(message), id: id)
                self.breakContinuity(id: id)
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, let id = self.runID else { return }
                if !self.session.isRunning { self.session.startRunning() }
                self.emit(.running, id: id)
                self.breakContinuity(id: id)
            }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func start(position: AVCaptureDevice.Position, id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.runID = id
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configure(position: position, id: id)
            case .notDetermined:
                self.emit(.requestingPermission, id: id)
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    self?.queue.async { [weak self] in
                        guard let self, self.runID == id else { return }
                        if granted { self.configure(position: position, id: id) } else { self.emit(.denied, id: id) }
                    }
                }
            case .denied: self.emit(.denied, id: id)
            case .restricted: self.emit(.restricted, id: id)
            @unknown default: self.emit(.unavailable, id: id)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.runID = nil
            self.activeDevice = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func setOrientation(_ value: AVCaptureVideoOrientation) {
        queue.async { [weak self] in
            guard let self, self.orientation != value else { return }
            self.orientation = value
            self.applyOutputOrientation()
            if let id = self.runID { self.breakContinuity(id: id) }
        }
    }

    private func configure(position: AVCaptureDevice.Position, id: UUID) {
        guard runID == id else { return }
        emit(.starting, id: id)
        if session.isRunning { session.stopRunning() }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTrueDepthCamera], mediaType: .video, position: position).devices
        guard let device = devices.first else { emit(.unavailable, id: id); return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            else if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                emit(.unavailable, id: id)
                return
            }
            session.addInput(input)
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
            applyOutputOrientation()
            session.commitConfiguration()
            activeDevice = device
            sourceContinuity = CameraSourceContinuity()
            lastProcessed = -Double.infinity
            session.startRunning()
            emit(.running, id: id)
        } catch { emit(.failed(error.localizedDescription), id: id) }
    }

    private func applyOutputOrientation() {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = orientation }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let id = runID, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Duo's virtual front camera can switch lenses without changing this capture session.
        // Invalidate the old pose before delivering the first frame from a different physical camera.
        if let device = activeDevice {
            let source = device.activePrimaryConstituent ?? device
            if sourceContinuity.changed(to: source.uniqueID) { breakContinuity(id: id) }
        }
        if let reason = diagnosticRecorder?.append(sampleBuffer) { finishDiagnostic(reason: reason) }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time.isFinite, time - lastProcessed >= 1.0 / 12 else { return }
        lastProcessed = time
        autoreleasepool {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
                let people = try (request.results ?? []).map { observation in
                    let recognized = try observation.recognizedPoints(.all)
                    var points: [PoseJoint: PosePoint] = [:]
                    for (joint, visionJoint) in Self.joints {
                        if let point = recognized[visionJoint] {
                            points[joint] = PosePoint(x: point.location.x, y: point.location.y, confidence: Double(point.confidence))
                        }
                    }
                    return BodyPose(points: points)
                }.filter { $0.points.values.contains(where: { $0.isValid && $0.confidence > 0 }) }
                let captured = CapturedPose(frame: PoseFrame(timestamp: time, width: Double(CVPixelBufferGetWidth(pixels)),
                    height: Double(CVPixelBufferGetHeight(pixels)), people: people),
                    latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000, revision: request.revision,
                    cameraGeometry: activeDevice.map { VisionCameraGeometry(deviceType: $0.deviceType.rawValue,
                        zoomFactor: Double($0.videoZoomFactor), reportedFormatFieldOfViewDegrees: Double($0.activeFormat.videoFieldOfView)) })
                DispatchQueue.main.async { [weak self] in self?.onFrame?(id, captured) }
            } catch {
                emit(.failed(error.localizedDescription), id: id)
                breakContinuity(id: id)
            }
        }
    }

    private func emit(_ state: PoseCameraState, id: UUID) {
        DispatchQueue.main.async { [weak self] in self?.onState?(id, state) }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard diagnosticRecorder != nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil).map { String(describing: $0) }
        diagnosticRecorder?.event(VisionDiagnosticEvent(kind: "captureDropped",
            lastCapturePTS: pts.isFinite ? pts : nil, detail: reason))
    }
    private func breakContinuity(id: UUID) {
        DispatchQueue.main.async { [weak self] in self?.onDiscontinuity?(id) }
    }

    private static let joints: [(PoseJoint, VNHumanBodyPoseObservation.JointName)] = [
        (.nose, .nose), (.neck, .neck), (.root, .root), (.leftEye, .leftEye), (.rightEye, .rightEye),
        (.leftEar, .leftEar), (.rightEar, .rightEar), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.rightHip, .rightHip), (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
    ]
}
