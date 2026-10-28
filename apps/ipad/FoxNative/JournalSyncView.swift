import FoxSyncCore
import SwiftUI
import UniformTypeIdentifiers

struct JournalSyncView: View {
    @ObservedObject var journal: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var invitation: SyncInvitation?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("个人资料库") {
                    if journal.syncState?.vault == nil {
                        Label("尚未配对", systemImage: "link")
                        Button { importing = true } label: { Label("选择配对文件", systemImage: "doc.badge.plus") }
                            .accessibilityIdentifier("sync-import").disabled(journal.syncing)
                        if let invitation {
                            LabeledContent("服务器", value: invitation.endpoint.host ?? "")
                            LabeledContent("资料库", value: invitation.vault)
                            Button("确认配对并同步本机图文") { Task { await journal.pair(invitation) } }
                                .disabled(journal.syncing).accessibilityIdentifier("sync-confirm")
                        }
                    } else {
                        Label("已配对", systemImage: "link.circle.fill")
                        LabeledContent("待上传修订", value: "\(journal.syncState?.pending ?? 0)")
                        LabeledContent("冲突修订", value: "\(journal.syncState?.conflicts ?? 0)")
                        if let count = journal.syncState?.blocked, count > 0 {
                            Text("\(count) 个修订暂不能上传：单张照片上限 25 MiB，文字与元数据约 64 KiB。原件和后续更正仍保留在本机及备份中，其他记录正常同步。")
                                .foregroundStyle(.orange)
                        }
                        if let date = journal.lastSync { LabeledContent("最近连接", value: date.formatted(date: .abbreviated, time: .shortened)) }
                        Button { Task { await journal.synchronize() } } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
                            .disabled(journal.syncing).accessibilityIdentifier("sync-now")
                    }
                    if journal.syncing { ProgressView("正在同步") }
                    if let error = journal.syncError ?? importError { Text(error).foregroundStyle(.red).accessibilityIdentifier("sync-error") }
                }
                ForEach(journal.syncConflicts) { conflict in
                    Section("需要核对") {
                        Text("本机：\(conflict.local?.note ?? (conflict.local == nil ? "已删除" : "照片记录"))")
                        conflictPhotos(conflict.local?.photos.map(\.id) ?? [])
                        Text("服务器：\(conflict.remote?.note ?? (conflict.remoteDeleted ? "已删除" : "照片记录"))")
                        conflictPhotos(conflict.remote?.photos.map(\.id) ?? [])
                        Text("本机 \(conflict.local?.photos.count ?? 0) 张照片 · 服务器 \(conflict.remote?.photos.count ?? 0) 张照片").foregroundStyle(.secondary)
                        Button("保留本机版本") { Task { await journal.resolveSync(conflict.id, keepLocal: true) } }.disabled(journal.syncing)
                        Button("采用服务器版本") { Task { await journal.resolveSync(conflict.id, keepLocal: false) } }.disabled(journal.syncing)
                    }
                }
            }
            .navigationTitle("同步资料库")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }.accessibilityIdentifier("sync-close")
            } }
            .task { await journal.refreshSyncState() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                Task {
                    do { invitation = try await journal.readInvitation(result.get()); importError = nil }
                    catch { invitation = nil; importError = "配对文件无效或已过期，请取得新的配对文件。" }
                }
            }
        }
    }
    @ViewBuilder private func conflictPhotos(_ ids: [UUID]) -> some View {
        if !ids.isEmpty {
            ScrollView(.horizontal) {
                HStack { ForEach(ids, id: \.self) { id in
                    JournalStoredPhoto(id: id, journal: journal, summary: true).frame(width: 120, height: 100).clipped()
                } }
            }
        }
    }
}
