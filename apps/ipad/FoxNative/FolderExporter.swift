import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FolderExporter: View {
    let url: URL
    let finished: (Bool) -> Void
    var body: some View { FolderPicker(mode: .export(url)) { finished($0 != nil) } }
}

struct FolderImporter: View {
    let finished: (URL?) -> Void
    var body: some View { FolderPicker(mode: .open, finished: finished) }
}

private struct FolderPicker: View {
    enum Mode {
        case export(URL), open
        var title: String { if case .export = self { return "导出副本" }; return "选择备份" }
        var cancelID: String { if case .export = self { return "file-export-cancel" }; return "file-import-cancel" }
    }
    let mode: Mode
    let finished: (URL?) -> Void
    @State private var completed = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(mode.title).font(.headline)
                Spacer()
                Button { complete(nil) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭文件面板").help("关闭文件面板").accessibilityIdentifier(mode.cancelID)
            }.padding(.horizontal, 20).background(.bar)
            Divider()
            NativeFolderPicker(mode: mode, finished: complete)
        }
    }
    private func complete(_ result: URL?) {
        guard !completed else { return }
        completed = true; finished(result)
    }
}

private struct NativeFolderPicker: UIViewControllerRepresentable {
    let mode: FolderPicker.Mode
    let finished: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker: UIDocumentPickerViewController
        switch mode {
        case .export(let url): picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        case .open: picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        }
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: (URL?) -> Void
        init(finished: @escaping (URL?) -> Void) { self.finished = finished }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished(nil) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished(urls.first) }
    }
}
