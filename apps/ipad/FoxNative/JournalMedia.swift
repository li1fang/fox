import AVFoundation
import FoxJournalCore
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct JournalMediaAccessKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var journalMediaAccessAllowed: Bool {
        get { self[JournalMediaAccessKey.self] }
        set { self[JournalMediaAccessKey.self] = newValue }
    }
}

struct JournalPhoto: Identifiable, Sendable {
    let id = UUID()
    let input: PhotoInput
    let thumbnail: Data
}

enum JournalMediaError: LocalizedError {
    case invalid, oversized
    var errorDescription: String? {
        switch self {
        case .invalid: return "无法读取这张照片，请选择 JPEG、PNG 或 HEIC 图片。"
        case .oversized: return "照片过大，请选择不超过 25 MB、8000 万像素的图片。"
        }
    }
}

enum JournalMedia {
    static func prepare(_ data: Data) throws -> JournalPhoto {
        guard data.count <= 25 * 1024 * 1024 else { throw JournalMediaError.oversized }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw JournalMediaError.invalid }
        let mime = try validate(source)
        return JournalPhoto(input: PhotoInput(data: data, mimeType: mime), thumbnail: try thumbnail(source))
    }

    private static func validate(_ source: CGImageSource) throws -> String {
        guard let type = CGImageSourceGetType(source) as String? else { throw JournalMediaError.invalid }
        let formats = [UTType.jpeg.identifier: "image/jpeg", UTType.png.identifier: "image/png", UTType.heic.identifier: "image/heic"]
        guard let mime = formats[type],
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { throw JournalMediaError.invalid }
        guard width.doubleValue * height.doubleValue <= 80_000_000 else { throw JournalMediaError.oversized }
        return mime
    }

    static func thumbnail(_ data: Data, maxPixelSize: Int = 1200) throws -> Data {
        guard (1...4096).contains(maxPixelSize) else { throw JournalMediaError.invalid }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw JournalMediaError.invalid }
        _ = try validate(source)
        return try thumbnail(source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(_ source: CGImageSource, maxPixelSize: Int = 1200) throws -> Data {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw JournalMediaError.invalid }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { throw JournalMediaError.invalid }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw JournalMediaError.invalid }
        return result as Data
    }
}

@MainActor
final class JournalPhotoSelection: ObservableObject {
    @Published var items: [JournalPhoto] = []
    @Published private(set) var loading = false
    @Published var error: String?

    func load(_ loader: () async throws -> Data?) async {
        guard !loading else { return }
        guard items.count < 6 else { error = "一次最多添加 6 张新照片。"; return }
        loading = true; error = nil
        defer { loading = false }
        do {
            guard let data = try await loader() else { return }
            let photo = try await Task.detached(priority: .userInitiated) { try JournalMedia.prepare(data) }.value
            items.append(photo)
        } catch {
            self.error = (error as? JournalMediaError)?.errorDescription ?? "照片读取失败，已有输入已保留。请重试。"
        }
    }
}

struct JournalPhotoPicker: View {
    @Environment(\.journalMediaAccessAllowed) private var mediaAccessAllowed
    @ObservedObject var selection: JournalPhotoSelection
    var disabled = false
    var showPreviews = true
    var showActions = true
    var showErrors = true
    @State private var photoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var requestingCamera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showPreviews && !selection.items.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(selection.items) { photo in
                            Image(uiImage: UIImage(data: photo.thumbnail) ?? UIImage())
                                .resizable().scaledToFill().frame(width: 112, height: 112).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("待保存照片").accessibilityIdentifier("journal-draft-photo")
                                .overlay(alignment: .topTrailing) {
                                    Button { selection.items.removeAll { $0.id == photo.id } } label: {
                                        Image(systemName: "xmark.circle.fill").font(.title2)
                                            .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7))
                                            .frame(width: 44, height: 44)
                                    }.accessibilityLabel("移除待保存照片")
                                }
                        }
                    }
                }
            }
            if showActions { HStack(spacing: 8) {
                Button { Task { await openCamera() } } label: { Image(systemName: "camera").frame(width: 44, height: 44) }
                    .accessibilityLabel("拍照").accessibilityIdentifier("journal-camera").help("拍照")
                if !mediaAccessAllowed {
                    Button {} label: { Image(systemName: "photo.on.rectangle").frame(width: 44, height: 44) }
                        .accessibilityLabel("选择照片").help("选择照片")
                } else {
                    PhotosPicker(selection: $photoItem, matching: .images, preferredItemEncoding: .current) {
                        Image(systemName: "photo.on.rectangle").frame(width: 44, height: 44)
                    }.accessibilityLabel("选择照片").help("选择照片")
                }
                if selection.loading || requestingCamera { ProgressView().accessibilityLabel("正在读取照片") }
                if ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1",
                   ProcessInfo.processInfo.environment["FOX_UI_JOURNAL_PHOTO_DATA"] != nil {
                    Text("测试照片").font(.caption).foregroundStyle(.red)
                }
            }.font(.system(size: 20)) }
            if showErrors, let error = selection.error {
                Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("journal-photo-error")
            }
        }
        .disabled(disabled || selection.loading || requestingCamera)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                await selection.load { try await item.loadTransferable(type: Data.self) }
                photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            JournalCameraView { result in
                showingCamera = false
                switch result {
                case .success(let data):
                    if let data { Task { await selection.load { data } } }
                case .failure:
                    selection.error = "照片处理失败，已有输入仍保留。请重试。"
                }
            }.ignoresSafeArea()
        }
    }

    private func openCamera() async {
        guard mediaAccessAllowed else { return }
        let environment = ProcessInfo.processInfo.environment
        if environment["FOX_UI_TESTING"] == "1" {
            if environment["FOX_UI_JOURNAL_CAMERA"] == "denied" { selection.error = "相机访问被拒绝；仍可选择照片或保存文字。"; return }
            if let encoded = environment["FOX_UI_JOURNAL_PHOTO_DATA"] {
                await selection.load { Data(base64Encoded: encoded) }; return
            }
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            selection.error = "此设备相机不可用；仍可选择照片或保存文字。"; return
        }
        requestingCamera = true
        defer { requestingCamera = false }
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        if granted { showingCamera = true }
        else { selection.error = "相机访问被拒绝；可在系统设置中授权，或继续保存文字。" }
    }
}

private struct JournalCameraView: UIViewControllerRepresentable {
    let completed: (Result<Data?, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completed: (Result<Data?, Error>) -> Void
        init(completed: @escaping (Result<Data?, Error>) -> Void) { self.completed = completed }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completed(.success(nil)) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { completed(.failure(JournalMediaError.invalid)); return }
            Task {
                let data = await Task.detached(priority: .userInitiated) { image.jpegData(compressionQuality: 0.92) }.value
                if let data { completed(.success(data)) }
                else { completed(.failure(JournalMediaError.invalid)) }
            }
        }
    }
}

struct JournalStoredPhoto: View {
    let id: UUID
    @ObservedObject var journal: JournalStore
    var summary = false
    @State private var bytes: Data?
    @State private var failed = false
    @State private var requestID: UUID?
    var body: some View {
        Group {
            if let bytes, let image = UIImage(data: bytes) {
                if summary {
                    if image.size.height > image.size.width * 2 {
                        GeometryReader { geometry in
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped()
                                .overlay(alignment: .bottomTrailing) {
                                    Label("长图", systemImage: "rectangle.portrait").font(.caption)
                                        .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(8)
                                }
                        }.frame(height: 180)
                    } else { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 200) }
                } else { Image(uiImage: image).resizable().scaledToFit() }
            }
            else if failed {
                VStack(spacing: 12) {
                    Label("照片暂时无法读取", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    if !summary { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                        .accessibilityLabel("重试读取照片")
                    }
                }.frame(maxWidth: .infinity, minHeight: 120)
            }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
        }.task(id: id) { await load() }
    }
    private func load() async {
        let request = UUID()
        requestID = request; failed = false; bytes = nil
        do {
            let loaded = try await journal.thumbnail(id)
            // A replaced photo must not receive an older asynchronous result.
            guard requestID == request, !Task.isCancelled else { return }
            bytes = loaded
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            failed = true
        }
    }
}
