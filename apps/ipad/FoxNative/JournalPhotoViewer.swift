import SwiftUI

struct JournalPhotoViewer: View {
    let photo: UUID
    @ObservedObject var journal: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var request = 0
    @State private var direction = 0
    @State private var percent = 100
    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    JournalZoomablePhoto(image: image, request: request, direction: direction) { percent = $0 }
                        .accessibilityIdentifier("journal-full-photo")
                } else if let error {
                    VStack(spacing: 20) {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        Button { Task { await load() } } label: { Label("重试读取", systemImage: "arrow.clockwise") }
                    }
                } else { ProgressView("正在读取照片") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
                .navigationTitle("照片").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                    ToolbarItemGroup(placement: .bottomBar) {
                        zoomButton("缩小", icon: "minus.magnifyingglass", direction: -1)
                        Spacer()
                        Text("\(percent)%").monospacedDigit().font(.caption).accessibilityIdentifier("photo-zoom-level")
                        Spacer()
                        zoomButton("适合屏幕", icon: "arrow.down.right.and.arrow.up.left", direction: 0)
                        zoomButton("放大", icon: "plus.magnifyingglass", direction: 1)
                    }
                }.task(id: photo) { await load() }
        }
    }
    private func zoomButton(_ title: String, icon: String, direction value: Int) -> some View {
        Button { direction = value; request += 1 } label: { Image(systemName: icon).frame(width: 44, height: 44) }
            .accessibilityLabel(title).help(title).disabled(image == nil)
    }
    private func load() async {
        image = nil; error = nil
        do {
            let bytes = try await journal.photoData(photo)
            let rendered = try await Task.detached(priority: .userInitiated) {
                try JournalMedia.thumbnail(bytes, maxPixelSize: 4096)
            }.value
            guard !Task.isCancelled, let decoded = UIImage(data: rendered) else { return }
            image = decoded
        } catch { if !Task.isCancelled { self.error = "照片暂时无法读取" } }
    }
}

private struct JournalZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    let request: Int
    let direction: Int
    let onScale: (Int) -> Void
    func makeUIView(context: Context) -> JournalPhotoScrollView { JournalPhotoScrollView(frame: .zero) }
    func updateUIView(_ view: JournalPhotoScrollView, context: Context) {
        view.onScale = onScale
        if view.imageView.image !== image { view.setImage(image) }
        if view.lastRequest != request {
            view.lastRequest = request
            view.adjustZoom(direction)
        }
    }
}

final class JournalPhotoScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var lastRequest = -1
    var onScale: ((Int) -> Void)?
    private var measuredSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; backgroundColor = .systemBackground
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        imageView.contentMode = .scaleAspectFit; addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleTap.numberOfTapsRequired = 2; addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setImage(_ image: UIImage) {
        imageView.image = image; measuredSize = .zero; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        if measuredSize != bounds.size {
            measuredSize = bounds.size
            minimumZoomScale = 0.001; maximumZoomScale = 20; setZoomScale(1, animated: false)
            imageView.frame = CGRect(origin: .zero, size: image.size); contentSize = image.size
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            minimumZoomScale = fit; maximumZoomScale = max(3, fit * 8); setZoomScale(fit, animated: false)
        }
        centerImage()
    }
    func adjustZoom(_ direction: Int) {
        let target = direction == 0 ? minimumZoomScale : zoomScale * (direction > 0 ? 1.5 : 1 / 1.5)
        setZoomScale(max(minimumZoomScale, min(maximumZoomScale, target)), animated: false)
    }
    @objc private func toggleZoom() { adjustZoom(zoomScale > minimumZoomScale * 1.1 ? 0 : 1) }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        let value = Int((zoomScale * 100).rounded())
        DispatchQueue.main.async { [weak self] in self?.onScale?(value) }
    }
    private func centerImage() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - imageView.frame.height) / 2), left: max(0, (bounds.width - imageView.frame.width) / 2), bottom: 0, right: 0)
    }
}
