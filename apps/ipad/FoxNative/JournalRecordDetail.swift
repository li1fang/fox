import FoxJournalCore
import SwiftUI

struct JournalRecordDetail: View {
    let initial: CaptureRecord
    @ObservedObject var journal: JournalStore
    let close: () -> Void
    @State private var editing = false
    @State private var deleting = false
    @State private var error: String?
    @State private var viewedPhoto: PhotoAttachment?

    private var record: CaptureRecord { journal.records.first { $0.id == initial.id } ?? initial }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("登记时间").font(.caption).foregroundStyle(.secondary)
                        Text(record.recordedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let occurred = record.occurred {
                        Text("发生于 \(occurred.start.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let note = record.note { Text(note).font(.body).textSelection(.enabled).accessibilityIdentifier("journal-detail-note") }
                    ForEach(Array(record.photos.enumerated()), id: \.element.id) { index, photo in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("照片 \(index + 1) / \(record.photos.count)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { viewedPhoto = photo } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }
                                    .accessibilityLabel("查看完整照片").help("查看完整照片").accessibilityIdentifier("journal-open-photo-\(photo.id)")
                            }
                            JournalStoredPhoto(id: photo.id, journal: journal).frame(maxWidth: .infinity)
                                .accessibilityIdentifier(index == 0 ? "journal-saved-photo" : "journal-saved-photo-\(photo.id)")
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .onTapGesture { viewedPhoto = photo }
                        }
                    }
                    Text("修订 \(record.revision)").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("journal-revision")
                }.frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity).padding(24)
            }
            .navigationTitle("生活记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成", action: close) }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { editing = true } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("更正记录").accessibilityIdentifier("journal-edit").help("更正记录")
                    Menu {
                        Button(role: .destructive) { deleting = true } label: { Label("删除记录", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("更多操作")
                }
            }
            .sheet(isPresented: $editing) { JournalRecordEditor(initial: record, journal: journal) }
            .sheet(item: $viewedPhoto) { photo in JournalPhotoViewer(photo: photo.id, journal: journal) }
            .alert("删除这条记录及全部修订？", isPresented: $deleting) {
                Button("删除记录", role: .destructive) {
                    Task {
                        if await journal.delete(record) { close() }
                        else { error = journal.operationError }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { Text("此前导出的备份不会被删除。") }
            .alert("未删除", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
            .disabled(journal.busy)
        }.interactiveDismissDisabled(journal.busy)
    }
}

private struct JournalRecordEditor: View {
    @ObservedObject var journal: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: CaptureRecord
    @State private var note: String
    @State private var kept: Set<UUID>
    @StateObject private var photos = JournalPhotoSelection()
    @State private var error: String?
    @State private var conflict = false
    @State private var discarding = false
    @State private var reloading = false
    @State private var loadingLatest = false
    @FocusState private var enteringNote: Bool

    init(initial: CaptureRecord, journal: JournalStore) {
        self.journal = journal
        _baseline = State(initialValue: initial)
        _note = State(initialValue: initial.note ?? "")
        _kept = State(initialValue: Set(initial.photos.map(\.id)))
    }

    private var dirty: Bool { note != (baseline.note ?? "") || kept != Set(baseline.photos.map(\.id)) || !photos.items.isEmpty }
    private var canSubmit: Bool {
        dirty && !journal.busy && !photos.loading && !loadingLatest && kept.count + photos.items.count <= 12 &&
            (!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !kept.isEmpty || !photos.items.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("journal-edit-error")
                        if conflict {
                            Button("载入最新版本") { reloading = true }.accessibilityIdentifier("journal-reload-latest")
                                .disabled(photos.loading || loadingLatest)
                        }
                        if loadingLatest { ProgressView("载入中…") }
                    }
                }
                Section("留言") {
                    TextField("留言", text: $note, axis: .vertical).lineLimit(3...20)
                        .focused($enteringNote)
                        .accessibilityIdentifier("journal-edit-note")
                }
                Section("照片") {
                    ForEach(baseline.photos.filter { kept.contains($0.id) }) { photo in
                        HStack(alignment: .top) {
                            JournalStoredPhoto(id: photo.id, journal: journal).frame(height: 180)
                            Button(role: .destructive) { _ = kept.remove(photo.id) } label: {
                                Image(systemName: "minus.circle").frame(width: 44, height: 44)
                            }.accessibilityLabel("从当前记录移除照片")
                        }
                    }
                    JournalPhotoPicker(selection: photos, disabled: journal.busy)
                    if kept.count + photos.items.count > 12 { Text("每条记录最多保留 12 张照片。").foregroundStyle(.red) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(journal.busy || loadingLatest)
            .navigationTitle("更正记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if dirty { discarding = true } else { dismiss() } }.disabled(journal.busy || photos.loading || loadingLatest)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        enteringNote = false
                        Task {
                            let result = await journal.revise(baseline, note: note,
                                keepPhotoIDs: baseline.photos.map(\.id).filter { kept.contains($0) }, photos: photos.items)
                            if result != nil { dismiss() }
                            else { error = journal.operationError; conflict = journal.revisionConflict }
                        }
                    }.disabled(!canSubmit).accessibilityIdentifier("journal-edit-save")
                }
            }
            .confirmationDialog("放弃未保存的更正？", isPresented: $discarding, titleVisibility: .visible) {
                Button("放弃更正", role: .destructive) { dismiss() }
            }
            .alert("放弃当前更正并载入最新版本？", isPresented: $reloading) {
                Button("载入最新版本", role: .destructive) {
                    guard !loadingLatest, !photos.loading else { return }
                    loadingLatest = true
                    Task {
                        defer { loadingLatest = false }
                        guard let latest = await journal.latest(baseline.id) else { error = "暂时无法读取最新记录，当前更正仍保留。"; return }
                        baseline = latest; note = latest.note ?? ""; kept = Set(latest.photos.map(\.id))
                        photos.items = []; error = nil; conflict = false
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }.interactiveDismissDisabled(dirty || journal.busy || photos.loading || loadingLatest)
    }
}
