import FoxJournalCore
import FoxSyncCore
import Foundation
import SwiftUI

// Repository initialization and disk access stay off the main actor.
struct PreparedJournalBackup: Identifiable {
    let id: UUID
    let url: URL
    let records: Int
    let photos: Int
}

private actor JournalWorker {
    let directory: URL
    let exportDirectory: URL
    let reset: Bool
    var failSaveOnce: Bool
    var conflictOnce: Bool
    private var repository: LocalJournalRepository?
    private var syncEngine: JournalSyncEngine?
    private let credentials: any SyncCredentialStore
    private let syncRPC: (any SyncRPC)?
    private let previews = NSCache<NSUUID, NSData>()

    init(directory: URL, exportDirectory: URL, reset: Bool, failSaveOnce: Bool, conflictOnce: Bool,
         credentials: any SyncCredentialStore, syncRPC: (any SyncRPC)?) {
        self.directory = directory
        self.exportDirectory = exportDirectory
        self.reset = reset
        self.failSaveOnce = failSaveOnce
        self.conflictOnce = conflictOnce
        self.credentials = credentials; self.syncRPC = syncRPC
        previews.countLimit = 80
        previews.totalCostLimit = 32 * 1024 * 1024
    }

    private func open() throws -> LocalJournalRepository {
        if let repository { return repository }
        if reset, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        let opened = try LocalJournalRepository(directory: directory)
        repository = opened
        return opened
    }

    func list(offset: Int = 0) throws -> [CaptureRecord] {
        try open().list(JournalQuery(limit: 51, offset: offset))
    }

    func syncState() throws -> (JournalSyncStatus, [JournalSyncConflict]) {
        let r = try open()
        // A claim may survive a failed local transaction in Keychain. Recover it
        // before presenting an unpaired state; this does not contact the server.
        if syncEngine == nil, try r.syncStatus().vault == nil {
            syncEngine = try JournalSyncEngine.paired(repository: r, credentials: credentials, rpc: syncRPC)
        }
        return (try r.syncStatus(), try r.syncConflicts())
    }
    func synchronize() async throws {
        if syncEngine == nil { syncEngine = try JournalSyncEngine.paired(repository: open(), credentials: credentials, rpc: syncRPC) }
        guard let syncEngine else { throw SyncClientError.missingCredentials }
        _ = try await syncEngine.run()
    }
    func invitation(_ url: URL) throws -> SyncInvitation {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 16_384 else { throw SyncClientError.invalidPairing }
        return try SyncInvitation.decode(Data(contentsOf: url))
    }
    func pair(_ invitation: SyncInvitation, name: String) async throws {
        syncEngine = try await JournalSyncEngine.pair(repository: open(), invitation: invitation, credentials: credentials, name: name)
    }
    func resolve(_ id: UUID, keepLocal: Bool) throws { try open().resolveSyncConflict(id, keepLocal: keepLocal) }

    func save(_ draft: CaptureDraft) throws -> CaptureRecord {
        if failSaveOnce {
            failSaveOnce = false
            throw JournalError.ioFailure
        }
        return try open().record(draft)
    }

    func get(_ id: UUID) throws -> CaptureRecord? { try open().get(id) }
    func photoData(_ id: UUID) throws -> Data { try open().photoData(id) }
    func thumbnail(_ id: UUID) throws -> Data {
        if let cached = previews.object(forKey: id as NSUUID) { return cached as Data }
        let bytes = try JournalMedia.thumbnail(open().photoData(id))
        previews.setObject(bytes as NSData, forKey: id as NSUUID, cost: bytes.count)
        return bytes
    }

    func revise(_ record: CaptureRecord, edit: CaptureEdit) throws -> CaptureRecord {
        let repository = try open()
        if conflictOnce {
            conflictOnce = false
            var newer = CaptureEdit(from: record); newer.note = "另一处已更正"
            _ = try repository.revise(record.id, expectedRevision: record.revision, edit: newer)
        }
        return try repository.revise(record.id, expectedRevision: record.revision, edit: edit)
    }

    func delete(_ record: CaptureRecord) throws -> CleanupReport {
        try open().delete(record.id, expectedRevision: record.revision)
    }

    func backup() throws -> PreparedJournalBackup {
        let id = UUID()
        let parent = exportDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let url = parent.appendingPathComponent("Fox-Backup-\(id.uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            let manifest = try open().exportBackup(to: url)
            return PreparedJournalBackup(id: id, url: url, records: manifest.records.count, photos: manifest.photos.count)
        } catch {
            try? FileManager.default.removeItem(at: parent)
            throw error
        }
    }

    func discardBackup(_ backup: PreparedJournalBackup) {
        let parent = backup.url.deletingLastPathComponent().standardizedFileURL
        guard parent.deletingLastPathComponent() == exportDirectory.standardizedFileURL,
              parent.lastPathComponent == backup.id.uuidString else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    func restore(_ url: URL) throws -> RestoreReceipt {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let repository = try open()
        var coordinationError: NSError?
        var result: Result<RestoreReceipt, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result { try repository.restoreBackup(from: source) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw JournalError.ioFailure }
        return try result.get()
    }
}

@MainActor
final class JournalStore: ObservableObject {
    enum Operation { case saving, revising, deleting, exporting, restoring }
    @Published var note = ""
    @Published private(set) var records: [CaptureRecord] = []
    @Published private(set) var operation: Operation?
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var saved = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var operationError: String?
    @Published private(set) var revisionConflict = false
    @Published var notice: String?
    @Published private(set) var syncState: JournalSyncStatus?
    @Published private(set) var syncConflicts: [JournalSyncConflict] = []
    @Published private(set) var syncing = false
    @Published private(set) var syncError: String?
    @Published private(set) var lastSync: Date?
    private let worker: JournalWorker
    #if DEBUG
    private let allowsDesignState: Bool
    #endif
    private var pendingDraft: CaptureDraft?
    private var nextOffset = 0

    convenience init() {
        let environment = ProcessInfo.processInfo.environment
        let testing = environment["FOX_UI_TESTING"] == "1"
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fox", isDirectory: true)
            .appendingPathComponent(testing ? "UITestJournal" : "Journal", isDirectory: true)
        let exports = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(testing ? "FoxUITestJournalExports" : "FoxJournalExports", isDirectory: true)
        self.init(directory: directory, exportDirectory: exports,
            reset: testing && ProcessInfo.processInfo.arguments.contains("--ui-testing-reset"),
            failSaveOnce: testing && environment["FOX_UI_FAIL_JOURNAL_SAVE_ONCE"] == "1",
            conflictOnce: testing && environment["FOX_UI_JOURNAL_CONFLICT_ONCE"] == "1")
    }

    init(directory: URL, exportDirectory: URL, reset: Bool = false, failSaveOnce: Bool = false, conflictOnce: Bool = false,
         credentials: any SyncCredentialStore = SyncKeychain(), syncRPC: (any SyncRPC)? = nil) {
        #if DEBUG
        allowsDesignState = directory.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.appendingPathComponent("FoxDesign").path + "/")
        #endif
        worker = JournalWorker(directory: directory, exportDirectory: exportDirectory,
            reset: reset, failSaveOnce: failSaveOnce, conflictOnce: conflictOnce, credentials: credentials, syncRPC: syncRPC)
    }

    var saving: Bool { operation == .saving }
    func refreshSyncState() async {
        do { let value = try await worker.syncState(); syncState = value.0; syncConflicts = value.1 }
        catch { syncError = "暂时无法读取同步状态；本机记录仍保留。" }
    }
    func readInvitation(_ url: URL) async throws -> SyncInvitation { try await worker.invitation(url) }
    func pair(_ invitation: SyncInvitation) async {
        guard !syncing, operation != .restoring else { return }
        syncing = true; syncError = nil
        defer { syncing = false }
        do { try await worker.pair(invitation, name: UIDevice.current.userInterfaceIdiom == .pad ? "Fox iPad" : "Fox iPhone") }
        catch { syncError = "配对未完成。请检查局域网权限、服务器或配对文件有效期；不要删除本机记录。" }
        await refreshSyncState()
        if syncError == nil { await performSync() }
    }
    func synchronize(ifPairedOnly: Bool = false) async {
        guard !syncing, operation != .restoring else { return }
        // Reserve ownership before any suspension, including the state refresh.
        syncing = true; syncError = nil
        defer { syncing = false }
        if ifPairedOnly {
            await refreshSyncState()
            guard syncState?.vault != nil else { return }
        }
        await performSync()
    }
    private func performSync() async {
        do { try await worker.synchronize(); lastSync = Date() }
        catch SyncClientError.wireLimit { syncError = "部分记录或照片超过同步上限，原件仍在本机；未完成的内容会继续保留。" }
        catch SyncClientError.missingCredentials { syncError = "配对凭据不可用。请先解锁；若仍失败，需要恢复配对，不要清除记录。" }
        catch { syncError = "同步未完成。本机记录和待上传内容仍保留，请检查网络、局域网权限及服务器身份后重试。" }
        await refreshSyncState(); await load()
    }
    func resolveSync(_ id: UUID, keepLocal: Bool) async {
        guard !syncing, operation != .restoring else { return }
        syncing = true; syncError = nil
        defer { syncing = false }
        do { try await worker.resolve(id, keepLocal: keepLocal); await performSync() }
        catch { syncError = "冲突尚未处理。请先同步取得完整远端版本，再重试。" }
        await refreshSyncState(); await load()
    }
    #if DEBUG
    func presentDesignState(_ scenario: DesignScenario) {
        guard allowsDesignState else { return }
        if scenario == .loading { loading = true }
    }
    #endif
    var busy: Bool { operation != nil || loading }
    var canSave: Bool { canSave(photos: []) }
    func canSave(photos: [JournalPhoto]) -> Bool {
        !busy && (!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty)
    }

    func load(more: Bool = false) async {
        guard !busy else { return }
        loading = true
        defer { loading = false }
        do {
            let offset = more ? nextOffset : 0
            applyPage(try await worker.list(offset: offset), offset: offset, more: more)
        } catch {
            loadError = "暂时无法读取本机记录，请重试。"
        }
    }

    @discardableResult
    func save(photos: [JournalPhoto] = []) async -> Bool {
        guard canSave(photos: photos) else { return false }
        operation = .saving
        saved = false
        defer { operation = nil }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        let inputs = photos.map(\.input)
        // Keep the exact ID, timestamp and content when retrying an unchanged draft.
        let samePhotos = pendingDraft.map { old in
            old.photos.count == inputs.count && zip(old.photos, inputs).allSatisfy { $0.data == $1.data && $0.mimeType == $1.mimeType }
        } ?? false
        if pendingDraft?.note != text || !samePhotos { pendingDraft = CaptureDraft(note: text, photos: inputs) }
        guard let draft = pendingDraft else { return false }
        do {
            let record = try await worker.save(draft)
            if !records.contains(where: { $0.id == record.id }) { nextOffset += 1 }
            records.removeAll { $0.id == record.id }
            records.insert(record, at: 0)
            note = ""
            pendingDraft = nil
            saveError = nil
            saved = true
            Task { await synchronize(ifPairedOnly: true) }
            return true
        } catch {
            saveError = "保存未完成，输入仍保留。请重试。"
            return false
        }
    }

    func photoData(_ id: UUID) async throws -> Data { try await worker.photoData(id) }
    func thumbnail(_ id: UUID) async throws -> Data { try await worker.thumbnail(id) }

    func latest(_ id: UUID) async -> CaptureRecord? {
        do {
            guard let record = try await worker.get(id) else { return nil }
            merge(record)
            return record
        } catch { return nil }
    }

    func revise(_ original: CaptureRecord, note: String, keepPhotoIDs: [UUID], photos: [JournalPhoto]) async -> CaptureRecord? {
        guard !busy else { return nil }
        operation = .revising; operationError = nil; revisionConflict = false
        defer { operation = nil }
        var edit = CaptureEdit(from: original)
        edit.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        edit.keepPhotoIDs = keepPhotoIDs; edit.newPhotos = photos.map(\.input)
        do {
            let record = try await worker.revise(original, edit: edit)
            merge(record)
            Task { await synchronize(ifPairedOnly: true) }
            return record
        } catch {
            revisionConflict = (error as? JournalError) == .revisionConflict
            operationError = revisionConflict ? "记录已有较新的版本，未覆盖。当前更正仍保留。" : "更正未保存，输入仍保留。请重试。"
            if revisionConflict { _ = await latest(original.id) }
            return nil
        }
    }

    func delete(_ record: CaptureRecord) async -> Bool {
        guard !busy else { return false }
        operation = .deleting; operationError = nil
        defer { operation = nil }
        do {
            let cleanup = try await worker.delete(record)
            if records.contains(where: { $0.id == record.id }) { nextOffset = max(0, nextOffset - 1) }
            records.removeAll { $0.id == record.id }
            if !cleanup.complete { notice = "记录已删除，部分照片仍待本机清理。" }
            Task { await synchronize(ifPairedOnly: true) }
            return true
        } catch {
            operationError = "删除未完成。记录可能已更新，请重新打开核对。"
            return false
        }
    }

    func prepareBackup() async -> PreparedJournalBackup? {
        guard !busy else { return nil }
        operation = .exporting; operationError = nil
        defer { operation = nil }
        do { return try await worker.backup() }
        catch { operationError = "备份准备失败，现有记录未被修改。请重试。"; return nil }
    }

    func discardBackup(_ backup: PreparedJournalBackup) async { await worker.discardBackup(backup) }

    func restoreBackup(from url: URL) async -> RestoreReceipt? {
        guard !busy, !syncing else { return nil }
        operation = .restoring; operationError = nil
        defer { operation = nil }
        do {
            let receipt = try await worker.restore(url)
            do { applyPage(try await worker.list(), offset: 0, more: false) }
            catch { loadError = "导入已提交，但列表暂时无法读取。请重试读取。" }
            return receipt
        } catch {
            operationError = (error as? JournalError) == .backupConflict ?
                "备份与本机记录存在冲突，未导入任何记录。" : "备份无效、照片不完整或无法读取，未导入任何记录。"
            return nil
        }
    }

    private func merge(_ record: CaptureRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
    }

    private func applyPage(_ page: [CaptureRecord], offset: Int, more: Bool) {
        let values = Array(page.prefix(50))
        if more {
            let existing = Set(records.map(\.id))
            records.append(contentsOf: values.filter { !existing.contains($0.id) })
        } else { records = values }
        nextOffset = offset + values.count
        canLoadMore = page.count > 50
        loadError = nil
    }
}
