import SwiftUI
import UniformTypeIdentifiers

struct JournalBackupView: View {
    @ObservedObject var journal: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: PreparedJournalBackup?
    @State private var prepared: PreparedJournalBackup?
    @State private var importing = false
    @State private var importURL: URL?
    @State private var confirmingImport = false
    @State private var error: String?
    @State private var status: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task {
                            error = nil; status = nil
                            guard let backup = await journal.prepareBackup() else { error = journal.operationError; return }
                            prepared = backup; exporting = backup
                        }
                    } label: { Label("导出完整备份", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("journal-export-backup")
                } header: { Text("导出") } footer: { Text("备份包含原文、历史修订和照片，未额外加密。") }
                Section {
                    Button { error = nil; status = nil; importURL = nil; importing = true } label: { Label("导入备份", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("journal-import-backup")
                } header: { Text("恢复") } footer: { Text("完整备份导入，不是设备同步。") }
                if journal.busy { Section { ProgressView("正在处理…") } }
                if let status { Section { Text(status).foregroundStyle(FoxStyle.accent).accessibilityIdentifier("journal-backup-status") } }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("journal-backup-error") } }
            }
            .disabled(journal.busy)
            .navigationTitle("备份与恢复").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(journal.busy) } }
            .fullScreenCover(item: $exporting, onDismiss: {
                if let backup = prepared {
                    prepared = nil
                    Task { await journal.discardBackup(backup) }
                }
            }) { backup in
                FolderExporter(url: backup.url) { exported in
                    if exported { status = "已导出 \(backup.records) 条记录、\(backup.photos) 张照片的完整备份。" }
                    exporting = nil
                }
            }
            .fullScreenCover(isPresented: $importing, onDismiss: {
                if importURL != nil { confirmingImport = true }
            }) {
                FolderImporter { url in importURL = url; importing = false }
            }
            .confirmationDialog("导入这份完整备份？", isPresented: $confirmingImport, titleVisibility: .visible) {
                Button("导入备份") {
                    guard let url = importURL else { return }
                    Task {
                        let receipt = await journal.restoreBackup(from: url)
                        importURL = nil
                        if let receipt { status = "已导入 \(receipt.inserted) 条，\(receipt.unchanged) 条已存在。" }
                        else { error = journal.operationError }
                    }
                }
                Button("取消", role: .cancel) { importURL = nil }
            } message: { Text("相同记录不会重复；如有版本冲突，将拒绝整份导入，不覆盖本机记录。") }
        }.interactiveDismissDisabled(journal.busy)
    }
}

