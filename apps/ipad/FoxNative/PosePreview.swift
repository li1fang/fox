import AVFoundation
import FoxTrainingCore
import SwiftUI
import UIKit

struct PosePreview: UIViewRepresentable {
    @ObservedObject var controller: VisionLabController
    func makeUIView(context: Context) -> PosePreviewView {
        let view = PosePreviewView()
        if controller.source == .camera { view.preview.session = controller.camera.session }
        view.camera = controller.camera
        view.onScreenOrientation = { [weak controller] orientation in controller?.screenOrientation = orientation }
        return view
    }
    func updateUIView(_ view: PosePreviewView, context: Context) {
        view.frameData = controller.latest?.frame
        view.mirrored = controller.frontCamera
        view.side = controller.arm
        view.subjectIndex = controller.subjectSelection.index
        view.selectionActive = controller.isCounting || controller.isPreparing
        view.fixture = controller.source == .fixture
        view.setNeedsLayout()
    }
}

final class PosePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    weak var camera: PoseCamera?
    var frameData: PoseFrame?
    var mirrored = true
    var fixture = false
    var side = ArmSide.left
    var subjectIndex: Int?
    var selectionActive = false
    var onScreenOrientation: ((VisionScreenOrientation) -> Void)?
    private var reportedOrientation: VisionScreenOrientation?
    private var captureOrientation: AVCaptureVideoOrientation?
    private weak var configuredConnection: AVCaptureConnection?
    private var previewOrientation: AVCaptureVideoOrientation?
    private var previewMirrored: Bool?
    private let bones = CAShapeLayer()
    private let dots = CAShapeLayer()
    private let selectedArm = CAShapeLayer()
    #if DEBUG
    private let previewIdentity = UUID()
    private let framingImage = CALayer()
    private var framingSize = CGSize.zero
    static func allowsFramingImage(environment: [String: String], fixture: Bool) -> Bool {
        fixture && environment["FOX_UI_TESTING"] == "1" && environment["FOX_POSE_IMAGE_FIXTURE"] == "1"
    }
    static func makeFramingImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.22, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            let edge = min(size.width, size.height) * 0.1
            for (point, color) in [(CGPoint.zero, UIColor.red), (CGPoint(x: size.width - edge, y: 0), .green),
                                   (CGPoint(x: 0, y: size.height - edge), .blue), (CGPoint(x: size.width - edge, y: size.height - edge), .yellow)] {
                color.setFill(); context.fill(CGRect(origin: point, size: CGSize(width: edge, height: edge)))
            }
            UIColor.white.setStroke()
            let border = UIBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3))
            border.lineWidth = 6; border.stroke()
        }
    }
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.videoGravity = .resizeAspect
        backgroundColor = .black
        #if DEBUG
        framingImage.contentsGravity = .resizeAspect
        layer.addSublayer(framingImage)
        #endif
        bones.fillColor = UIColor.clear.cgColor
        bones.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
        bones.lineWidth = 3
        dots.fillColor = UIColor.white.cgColor
        selectedArm.fillColor = UIColor.clear.cgColor
        selectedArm.strokeColor = UIColor.systemMint.cgColor
        selectedArm.lineWidth = 6
        [bones, dots, selectedArm].forEach { layer.addSublayer($0) }
        isAccessibilityElement = true
        accessibilityLabel = "相机与人体关键点"
        accessibilityIdentifier = "pose-preview"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateInterfaceOrientation(_ interface: UIInterfaceOrientation) {
        let orientation: AVCaptureVideoOrientation
        switch interface {
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        default: orientation = .portrait
        }
        let recordedOrientation: VisionScreenOrientation
        switch interface {
        case .portrait: recordedOrientation = .portrait
        case .portraitUpsideDown: recordedOrientation = .portraitUpsideDown
        case .landscapeLeft: recordedOrientation = .landscapeLeft
        case .landscapeRight: recordedOrientation = .landscapeRight
        default: recordedOrientation = .unknown
        }
        if reportedOrientation != recordedOrientation {
            reportedOrientation = recordedOrientation
            onScreenOrientation?(recordedOrientation)
        }
        if !fixture {
            if captureOrientation != orientation {
                captureOrientation = orientation
                camera?.setOrientation(orientation)
            }
            if let connection = preview.connection,
               configuredConnection !== connection || previewOrientation != orientation || previewMirrored != mirrored {
                if connection.isVideoOrientationSupported && connection.videoOrientation != orientation { connection.videoOrientation = orientation }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    if connection.isVideoMirrored != mirrored { connection.isVideoMirrored = mirrored }
                }
                configuredConnection = connection; previewOrientation = orientation; previewMirrored = mirrored
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateInterfaceOrientation(window?.windowScene?.interfaceOrientation ?? .portrait)
        backgroundColor = fixture ? UIColor(white: 0.15, alpha: 1) : .black
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if DEBUG
        let useImage = Self.allowsFramingImage(environment: ProcessInfo.processInfo.environment, fixture: fixture)
        framingImage.isHidden = !useImage
        framingImage.frame = bounds
        if useImage, let frameData {
            let size = CGSize(width: frameData.width, height: frameData.height)
            if framingSize != size {
                framingSize = size; framingImage.contents = Self.makeFramingImage(size: size).cgImage
            }
            framingImage.setAffineTransform(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
        }
        #endif
        [bones, dots, selectedArm].forEach { $0.frame = bounds }
        let bonePath = UIBezierPath(), dotPath = UIBezierPath(), armPath = UIBezierPath()
        if let frameData {
            func display(_ point: PosePoint) -> CGPoint {
                let p = PoseGeometry.project(point, imageWidth: frameData.width, imageHeight: frameData.height,
                    viewWidth: bounds.width, viewHeight: bounds.height, mirrored: mirrored)
                return CGPoint(x: p.x, y: p.y)
            }
            for (personIndex, person) in frameData.people.enumerated() {
                let points = person.points.filter { $0.value.isValid && $0.value.confidence >= 0.35 }
                for (from, to) in Self.connections {
                    if let a = points[from], let b = points[to] { bonePath.move(to: display(a)); bonePath.addLine(to: display(b)) }
                }
                for point in points.values {
                    let p = display(point)
                    dotPath.append(UIBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)))
                }
                if personIndex == subjectIndex || (!selectionActive && frameData.people.count == 1) {
                    for index in 0..<2 {
                        if let a = points[side.joints[index]], let b = points[side.joints[index + 1]], min(a.confidence, b.confidence) >= 0.55 {
                            armPath.move(to: display(a)); armPath.addLine(to: display(b))
                        }
                    }
                }
            }
        }
        bones.path = bonePath.cgPath; dots.path = dotPath.cgPath; selectedArm.path = armPath.cgPath
        accessibilityValue = "\(frameData?.people.count ?? 0) 人"
        #if DEBUG
        if ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1" {
            accessibilityValue = "\(frameData?.people.count ?? 0) 人;preview=\(previewIdentity.uuidString)"
        }
        #endif
        CATransaction.commit()
    }

    private static let connections: [(PoseJoint, PoseJoint)] = [
        (.nose, .neck), (.nose, .leftEye), (.nose, .rightEye), (.leftEye, .leftEar), (.rightEye, .rightEar),
        (.neck, .leftShoulder), (.neck, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist), (.neck, .root), (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
    ]
}
