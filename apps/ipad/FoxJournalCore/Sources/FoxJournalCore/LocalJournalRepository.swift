import Foundation

public final class LocalJournalRepository: @unchecked Sendable {
    public let deviceID: UUID
    private let root: URL
    private let limits: JournalLimits
    let db: JournalDatabase
    // Serialize the connection and file operations together; SQLite coordinates other instances.
    private let lock = NSRecursiveLock()
    let checkpoint: ((JournalCheckpoint) throws -> Void)?
    private static let applicationID = 0x464F584A
    private static let manifestBytes = 16_777_216

    public convenience init(directory: URL, limits: JournalLimits = .init()) throws {
        try self.init(directory: directory, limits: limits, checkpoint: nil)
    }
    package init(directory: URL, limits: JournalLimits = .init(), checkpoint: ((JournalCheckpoint) throws -> Void)?) throws {
        guard limits.noteBytes > 0, limits.photosPerRecord > 0, limits.photoBytes > 0,
              limits.recordPhotoBytes > 0, limits.backupBytes > 0, limits.backupRecords > 0 else { throw JournalError.invalidInput("limits") }
        try JournalFiles.directory(directory, create: true)
        root = directory.resolvingSymlinksInPath().standardizedFileURL
        let databaseURL = root.appendingPathComponent("journal.sqlite")
        if FileManager.default.fileExists(atPath: databaseURL.path) { _ = try JournalFiles.regularFile(databaseURL, maximum: Int.max) }
        else if !(try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty { throw JournalError.unsafePath }
        db = try JournalDatabase(url: databaseURL)
        self.limits = limits; self.checkpoint = checkpoint
        deviceID = try Self.initialize(db)
        try JournalFiles.protect(root, directory: true); try JournalFiles.protect(databaseURL)
        guard try db.rows("PRAGMA journal_mode=WAL").first?.first?.text == "wal" else { throw JournalError.corruptStore }
        try db.execute("PRAGMA synchronous=FULL")
        for name in ["attachments", "staging"] {
            let directory = root.appendingPathComponent(name)
            try JournalFiles.directory(directory, create: true); try JournalFiles.protect(directory, directory: true)
        }
        _ = try cleanup()
    }

    public func record(_ draft: CaptureDraft) throws -> CaptureRecord {
        try locked {
            try transaction {
                try JournalValidation.date(draft.recordedAt)
                let photos = try descriptors(draft.photos)
                let source = draft.source ?? CaptureSource(deviceID: deviceID)
                let proposed = CaptureRecord(schemaVersion: 1, id: draft.id, revision: 1,
                    recordedAt: JournalValidation.canonical(draft.recordedAt), updatedAt: JournalValidation.canonical(draft.recordedAt),
                    timeZoneIdentifier: draft.timeZoneIdentifier, note: draft.note, photos: photos,
                    occurred: try JournalValidation.occurrence(draft.occurred), labels: draft.labels, source: source)
                try JournalValidation.record(proposed, limits: limits)
                if let existing = try getUnlocked(draft.id, includeDeleted: true) {
                    guard try !isTombstone(draft.id) else { throw JournalError.captureConflict }
                    let original = try historyUnlocked(draft.id)[0]
                    guard original.recordedAt == proposed.recordedAt, original.source == proposed.source,
                          original.note == proposed.note, original.occurred == proposed.occurred,
                          original.labels == proposed.labels, original.timeZoneIdentifier == proposed.timeZoneIdentifier,
                          original.photos.count == photos.count,
                          zip(original.photos, photos).allSatisfy({ $0.mimeType == $1.mimeType && $0.sha256 == $1.sha256 && $0.byteCount == $1.byteCount }) else {
                        throw JournalError.captureConflict
                    }
                    for photo in original.photos { try verifyPhoto(photo) }
                    return existing
                }
                for (photo, input) in zip(photos, draft.photos) { try writePhoto(input.data, descriptor: photo) }
                try insertRecord(proposed); try insertRevision(proposed)
                try enqueueSync(proposed.id, payload: proposed)
                try checkpoint?(.beforeCommit)
                return proposed
            }
        }
    }

    public func get(_ id: UUID) throws -> CaptureRecord? { try locked { try getUnlocked(id) } }
    public func history(_ id: UUID) throws -> [CaptureRecord] { try locked { try historyUnlocked(id) } }
    public func list(_ query: JournalQuery = .init()) throws -> [CaptureRecord] {
        try locked {
            guard (1...1000).contains(query.limit), query.offset >= 0 else { throw JournalError.invalidInput("pagination") }
            if let from = query.from { try JournalValidation.date(from) }
            if let before = query.before { try JournalValidation.date(before) }
            if let from = query.from, let before = query.before, from >= before { throw JournalError.invalidInput("range") }
            var predicates = ["NOT EXISTS (SELECT 1 FROM journal_tombstones t WHERE t.id=r.id)"], bindings: [SQLValue] = []
            if let text = query.text {
                guard text.utf8.count <= limits.noteBytes else { throw JournalError.invalidInput("search") }
                predicates.append("instr(coalesce(r.note, ''), ?) > 0"); bindings.append(.text(text))
            }
            if let label = query.label {
                predicates.append("EXISTS (SELECT 1 FROM labels l WHERE l.record_id=r.id AND l.label=?)"); bindings.append(.text(label))
            }
            let time = query.timeBasis == .recorded ? "r.recorded_ms" : "r.timeline_ms"
            if let from = query.from { predicates.append("\(time) >= ?"); bindings.append(.number(from.timeIntervalSince1970 * 1000)) }
            if let before = query.before { predicates.append("\(time) < ?"); bindings.append(.number(before.timeIntervalSince1970 * 1000)) }
            let condition = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
            bindings += [.integer(Int64(query.limit)), .integer(Int64(query.offset))]
            return try db.rows("SELECT v.payload FROM records r LEFT JOIN revisions v ON v.record_id=r.id AND v.revision=r.current_revision \(condition) ORDER BY \(time) DESC, r.id ASC LIMIT ? OFFSET ?", bindings).map { try decodeRecord($0[0]) }
        }
    }

    public func revise(_ id: UUID, expectedRevision: Int, edit: CaptureEdit, at: Date = Date()) throws -> CaptureRecord {
        try locked {
            try transaction {
                guard let previous = try getUnlocked(id) else { throw JournalError.notFound }
                guard previous.revision == expectedRevision else { throw JournalError.revisionConflict }
                guard previous.revision < Int(Int32.max) else { throw JournalError.invalidInput("revision limit") }
                try JournalValidation.date(at)
                guard Set(edit.keepPhotoIDs).count == edit.keepPhotoIDs.count else { throw JournalError.invalidInput("photo IDs") }
                let kept = try edit.keepPhotoIDs.map { id in
                    guard let photo = previous.photos.first(where: { $0.id == id }) else { throw JournalError.invalidInput("photo ID") }
                    try verifyPhoto(photo); return photo
                }
                let added = try descriptors(edit.newPhotos)
                let revised = CaptureRecord(schemaVersion: 1, id: id, revision: previous.revision + 1,
                    recordedAt: previous.recordedAt, updatedAt: JournalValidation.canonical(at),
                    timeZoneIdentifier: edit.timeZoneIdentifier, note: edit.note, photos: kept + added,
                    occurred: try JournalValidation.occurrence(edit.occurred), labels: edit.labels, source: previous.source)
                try JournalValidation.record(revised, limits: limits)
                guard revised.updatedAt >= previous.updatedAt else { throw JournalError.invalidInput("revision date") }
                for (photo, input) in zip(added, edit.newPhotos) { try writePhoto(input.data, descriptor: photo) }
                try db.execute("UPDATE records SET current_revision=?, timeline_ms=?, note=? WHERE id=? AND current_revision=?",
                    [.integer(Int64(revised.revision)), .number(revised.timelineAt.timeIntervalSince1970 * 1000),
                     revised.note.map(SQLValue.text) ?? .null, .text(key(id)), .integer(Int64(expectedRevision))])
                try insertRevision(revised)
                try enqueueSync(revised.id, payload: revised)
                try checkpoint?(.beforeCommit)
                return revised
            }
        }
    }

    public func delete(_ id: UUID, expectedRevision: Int) throws -> CleanupReport {
        try locked {
            let photoIDs: [UUID] = try transaction {
                guard let record = try getUnlocked(id) else { throw JournalError.notFound }
                guard record.revision == expectedRevision else { throw JournalError.revisionConflict }
                let photos = Set(try historyUnlocked(id).flatMap { $0.photos.map(\.id) })
                if try syncVault() != nil {
                    try enqueueSync(id, payload: nil)
                    try db.execute("INSERT INTO journal_tombstones VALUES(?)", [.text(key(id))])
                } else { try db.execute("DELETE FROM records WHERE id=?", [.text(key(id))]) }
                try checkpoint?(.beforeCommit)
                return Array(photos)
            }
            do { return try cleanup() }
            catch { return CleanupReport(pendingPhotoIDs: photoIDs, unrecognizedFiles: [], failure: String(describing: error)) }
        }
    }

    public func photoData(_ id: UUID) throws -> Data {
        try locked {
            try db.transaction {
                guard let photo = try photoDescriptor(id), try isReferenced(id) else { throw JournalError.notFound }
                try verifyPhoto(photo)
                let data = try Data(contentsOf: root.appendingPathComponent(photo.relativePath))
                guard data.count == photo.byteCount, JournalFiles.digest(data) == photo.sha256 else { throw JournalError.attachmentIntegrity }
                return data
            }
        }
    }

    public func cleanup() throws -> CleanupReport {
        try locked {
            try db.transaction {
                try checkDirectories()
                var pending: [UUID] = [], unrecognized: [String] = []
                let garbage = try db.rows("SELECT payload FROM photos WHERE NOT EXISTS (SELECT 1 FROM revision_photos p WHERE p.photo_id=photos.id) AND NOT EXISTS (SELECT 1 FROM sync_photo_refs s WHERE s.photo_id=photos.id) AND NOT EXISTS (SELECT 1 FROM sync_downloads d WHERE d.photo_id=photos.id)")
                for row in garbage {
                    let photo = try decodePhoto(row[0])
                    do {
                        try checkpoint?(.beforePhotoRemoval)
                        let file = root.appendingPathComponent(photo.relativePath)
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                        try db.execute("DELETE FROM photos WHERE id=?", [.text(key(photo.id))])
                    } catch { pending.append(photo.id) }
                }
                let retained = Set(try db.rows("SELECT payload FROM photos").map { try decodePhoto($0[0]).relativePath })
                let attachments = root.appendingPathComponent("attachments")
                for name in try FileManager.default.contentsOfDirectory(atPath: attachments.path) {
                    let path = "attachments/" + name
                    guard !retained.contains(path) else { continue }
                    let file = attachments.appendingPathComponent(name), stem = file.deletingPathExtension().lastPathComponent
                    guard let id = UUID(uuidString: stem), stem == key(id), JournalValidation.extensions.values.contains(file.pathExtension) else {
                        unrecognized.append(path); continue
                    }
                    let type = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
                    guard type == .typeRegular || type == .typeSymbolicLink else { unrecognized.append(path); continue }
                    do { try checkpoint?(.beforePhotoRemoval); try FileManager.default.removeItem(at: file) }
                    catch { pending.append(id) }
                }
                for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("staging"), includingPropertiesForKeys: nil) {
                    do { try FileManager.default.removeItem(at: file) }
                    catch { unrecognized.append("staging/" + file.lastPathComponent) }
                }
                return CleanupReport(pendingPhotoIDs: Array(Set(pending)).sorted { key($0) < key($1) }, unrecognizedFiles: unrecognized.sorted())
            }
        }
    }

    public func exportBackup(to destination: URL, at: Date = Date()) throws -> JournalBackup {
        try locked {
            try JournalValidation.date(at)
            try validateDestination(destination)
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".fox-backup-\(UUID())")
            do {
                // A write reservation keeps another instance from deleting photos during this snapshot.
                let manifest = try db.transaction {
                    let histories = try db.rows("SELECT id FROM records ORDER BY id").map { row -> JournalBackup.History in
                        guard let text = row[0].text, let id = UUID(uuidString: text) else { throw JournalError.corruptStore }
                        return JournalBackup.History(id: id, revisions: try historyUnlocked(id))
                    }
                    var inventory = try JournalValidation.histories(histories, limits: limits)
                    let evidence = try syncEvidence()
                    for op in evidence { for photo in op.payload?.photos ?? [] {
                        if let existing = inventory[photo.id], existing != photo { throw JournalError.attachmentIntegrity }
                        inventory[photo.id] = photo
                    } }
                    let deleted = try db.rows("SELECT id FROM journal_tombstones ORDER BY id").map { row -> UUID in
                        guard let text = row[0].text, let id = UUID(uuidString: text) else { throw JournalError.corruptStore }; return id
                    }
                    let extended = !deleted.isEmpty || !evidence.isEmpty
                    let manifest = JournalBackup(format: extended ? "fox.journal.backup.v2" : "fox.journal.backup.v1", createdAt: JournalValidation.canonical(at),
                        records: histories, photos: inventory.values.sorted { key($0.id) < key($1.id) },
                        deletedRecordIDs: extended ? deleted : nil, syncEvidence: extended ? evidence : nil)
                    let json = try JournalJSON.encoder().encode(manifest)
                    guard json.count <= Self.manifestBytes, json.count <= limits.backupBytes else { throw JournalError.invalidBackup }
                    var total = json.count
                    for photo in manifest.photos {
                        let sum = total.addingReportingOverflow(photo.byteCount)
                        guard !sum.overflow, sum.partialValue <= limits.backupBytes else { throw JournalError.invalidBackup }
                        total = sum.partialValue
                    }
                    try JournalFiles.directory(temporary, create: true)
                    try JournalFiles.directory(temporary.appendingPathComponent("attachments"), create: true)
                    for photo in manifest.photos {
                        try verifyPhoto(photo)
                        let target = temporary.appendingPathComponent(photo.relativePath)
                        try FileManager.default.copyItem(at: root.appendingPathComponent(photo.relativePath), to: target)
                        try JournalFiles.protect(target)
                        try JournalFiles.verify(target, photo: photo, limits: limits)
                        try checkpoint?(.backupPhotoCopied)
                    }
                    let manifestURL = temporary.appendingPathComponent("manifest.json")
                    try json.write(to: manifestURL, options: .atomic); try JournalFiles.protect(manifestURL)
                    return manifest
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                return manifest
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    }

    public func restoreBackup(from directory: URL) throws -> RestoreReceipt {
        try locked {
            try JournalFiles.directory(directory)
            let source = directory.resolvingSymlinksInPath().standardizedFileURL
            guard !isInside(source, parent: root) else { throw JournalError.unsafePath }
            let manifestURL = source.appendingPathComponent("manifest.json")
            let jsonBytes = try JournalFiles.regularFile(manifestURL, maximum: min(Self.manifestBytes, limits.backupBytes))
            let manifest: JournalBackup
            do { manifest = try JournalJSON.decodeBackup(Data(contentsOf: manifestURL)) }
            catch { throw JournalError.invalidBackup }
            guard ["fox.journal.backup.v1", "fox.journal.backup.v2"].contains(manifest.format) else { throw JournalError.unsupportedVersion }
            let extended = manifest.format == "fox.journal.backup.v2"
            guard extended || (manifest.deletedRecordIDs == nil && manifest.syncEvidence == nil) else { throw JournalError.invalidBackup }
            guard !extended || (manifest.deletedRecordIDs != nil && manifest.syncEvidence != nil) else { throw JournalError.invalidBackup }
            try JournalValidation.date(manifest.createdAt)
            var expected = try JournalValidation.histories(manifest.records, limits: limits)
            let evidence = manifest.syncEvidence ?? [], deleted = manifest.deletedRecordIDs ?? []
            guard Set(evidence.map(\.op_id)).count == evidence.count, Set(deleted).count == deleted.count else { throw JournalError.invalidBackup }
            let knownIDs = Set(manifest.records.map(\.id)).union(evidence.filter(\.deleted).compactMap { UUID(uuidString: $0.record_id) })
            guard Set(deleted).isSubset(of: knownIDs) else { throw JournalError.invalidBackup }
            for op in evidence {
                try op.validate()
                for photo in op.payload?.photos ?? [] {
                    if let existing = expected[photo.id], existing != photo { throw JournalError.invalidBackup }
                    expected[photo.id] = photo
                }
            }
            guard Set(manifest.photos.map(\.id)).count == manifest.photos.count,
                  expected.count == manifest.photos.count else { throw JournalError.invalidBackup }
            var total = jsonBytes
            if !manifest.photos.isEmpty { try JournalFiles.directory(source.appendingPathComponent("attachments")) }
            for photo in manifest.photos {
                guard expected[photo.id] == photo else { throw JournalError.invalidBackup }
                let sum = total.addingReportingOverflow(photo.byteCount)
                guard !sum.overflow, sum.partialValue <= limits.backupBytes else { throw JournalError.invalidBackup }
                total = sum.partialValue
                try JournalFiles.verify(source.appendingPathComponent(photo.relativePath), photo: photo, limits: limits)
            }
            return try transaction {
                // V2 is a portable history/evidence backup, never a clone of pairing credentials
                // or cursor. Restore it only into an empty unpaired store to avoid resurrecting data.
                if extended {
                    guard try syncVault() == nil, try db.rows("SELECT id FROM records").isEmpty,
                          try db.rows("SELECT id FROM sync_archive").isEmpty else { throw JournalError.backupConflict }
                }
                var inserted = 0, unchanged = 0
                for history in manifest.records {
                    if try getUnlocked(history.id) != nil {
                        guard try historyUnlocked(history.id) == history.revisions else { throw JournalError.backupConflict }
                        unchanged += 1
                    } else { inserted += 1 }
                }
                for photo in manifest.photos {
                    if let existing = try photoDescriptor(photo.id) {
                        guard existing == photo else { throw JournalError.backupConflict }
                        try verifyPhoto(existing)
                    } else {
                        let file = source.appendingPathComponent(photo.relativePath)
                        try JournalFiles.verify(file, photo: photo, limits: limits)
                        try writePhoto(Data(contentsOf: file), descriptor: photo)
                    }
                }
                for history in manifest.records where try getUnlocked(history.id) == nil {
                    guard let latest = history.revisions.last else { throw JournalError.invalidBackup }
                    try insertRecord(latest)
                    for record in history.revisions { try insertRevision(record) }
                    try replaceLabels(latest)
                    for record in history.revisions { try enqueueSync(record.id, payload: record) }
                }
                for id in deleted { try db.execute("INSERT INTO journal_tombstones VALUES(?)", [.text(key(id))]) }
                for op in evidence {
                    try db.execute("INSERT INTO sync_archive VALUES(?,?)", [.text(op.op_id), .text(try encoded(op))])
                    try retainSyncPhotos(op)
                }
                try checkpoint?(.beforeCommit)
                return RestoreReceipt(inserted: inserted, unchanged: unchanged)
            }
        }
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        do { try checkDirectories(); return try db.transaction(body) }
        catch { _ = try? cleanup(); throw error }
    }
    func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    private func checkDirectories() throws {
        for url in [root, root.appendingPathComponent("attachments"), root.appendingPathComponent("staging")] { try JournalFiles.directory(url) }
    }
    private func descriptors(_ inputs: [PhotoInput]) throws -> [PhotoAttachment] {
        guard inputs.count <= limits.photosPerRecord else { throw JournalError.invalidInput("photo count") }
        return try inputs.map { input in
            guard let ext = JournalValidation.extensions[input.mimeType], !input.data.isEmpty,
                  input.data.count <= limits.photoBytes else { throw JournalError.invalidInput("photo") }
            let id = UUID()
            return PhotoAttachment(id: id, mimeType: input.mimeType, byteCount: input.data.count,
                sha256: JournalFiles.digest(input.data), relativePath: "attachments/\(key(id)).\(ext)")
        }
    }
    func writePhoto(_ data: Data, descriptor: PhotoAttachment) throws {
        try JournalValidation.attachment(descriptor, limits: limits)
        guard data.count == descriptor.byteCount, JournalFiles.digest(data) == descriptor.sha256 else { throw JournalError.attachmentIntegrity }
        let final = root.appendingPathComponent(descriptor.relativePath)
        guard !FileManager.default.fileExists(atPath: final.path) else { throw JournalError.attachmentIntegrity }
        let temporary = root.appendingPathComponent("staging/\(key(descriptor.id)).pending")
        try data.write(to: temporary, options: .atomic); try JournalFiles.protect(temporary)
        let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
        try FileManager.default.moveItem(at: temporary, to: final)
        try checkpoint?(.photoWritten)
        try db.execute("INSERT INTO photos(id,payload) VALUES(?,?)", [.text(key(descriptor.id)), .text(try encoded(descriptor))])
    }
    func verifyPhoto(_ photo: PhotoAttachment) throws {
        try checkDirectories(); try JournalFiles.verify(root.appendingPathComponent(photo.relativePath), photo: photo, limits: JournalValidation.storedLimits)
    }
    func photoDescriptor(_ id: UUID) throws -> PhotoAttachment? {
        try db.rows("SELECT payload FROM photos WHERE id=?", [.text(key(id))]).first.map { try decodePhoto($0[0]) }
    }
    private func isReferenced(_ id: UUID) throws -> Bool {
        !(try db.rows("SELECT 1 FROM revision_photos WHERE photo_id=? UNION ALL SELECT 1 FROM sync_photo_refs WHERE photo_id=? UNION ALL SELECT 1 FROM sync_downloads WHERE photo_id=? LIMIT 1", [.text(key(id)), .text(key(id)), .text(key(id))])).isEmpty
    }
    func getUnlocked(_ id: UUID, includeDeleted: Bool = false) throws -> CaptureRecord? {
        if !includeDeleted, try isTombstone(id) { return nil }
        guard let row = try db.rows("SELECT v.payload FROM records r LEFT JOIN revisions v ON v.record_id=r.id AND v.revision=r.current_revision WHERE r.id=?", [.text(key(id))]).first else { return nil }
        return try decodeRecord(row[0])
    }
    func historyUnlocked(_ id: UUID) throws -> [CaptureRecord] {
        let history = try db.rows("SELECT payload FROM revisions WHERE record_id=? ORDER BY revision", [.text(key(id))]).map { try decodeRecord($0[0]) }
        guard !history.isEmpty else { throw JournalError.notFound }
        _ = try JournalValidation.histories([.init(id: id, revisions: history)], limits: JournalValidation.storedLimits, enforceBackupLimits: false)
        return history
    }
    func insertRecord(_ record: CaptureRecord) throws {
        try db.execute("INSERT INTO records(id,current_revision,recorded_ms,timeline_ms,note,provider,source_record_id) VALUES(?,?,?,?,?,?,?)",
            [.text(key(record.id)), .integer(Int64(record.revision)), .number(record.recordedAt.timeIntervalSince1970 * 1000),
             .number(record.timelineAt.timeIntervalSince1970 * 1000), record.note.map(SQLValue.text) ?? .null,
             record.source.provider.map(SQLValue.text) ?? .null, record.source.sourceRecordID.map(SQLValue.text) ?? .null])
    }
    func insertRevision(_ record: CaptureRecord) throws {
        try db.execute("INSERT INTO revisions(record_id,revision,payload) VALUES(?,?,?)",
            [.text(key(record.id)), .integer(Int64(record.revision)), .text(try encoded(record))])
        for photo in record.photos {
            try db.execute("INSERT INTO revision_photos(record_id,revision,photo_id) VALUES(?,?,?)",
                [.text(key(record.id)), .integer(Int64(record.revision)), .text(key(photo.id))])
        }
        try replaceLabels(record)
    }
    private func replaceLabels(_ record: CaptureRecord) throws {
        try db.execute("DELETE FROM labels WHERE record_id=?", [.text(key(record.id))])
        for label in record.labels { try db.execute("INSERT INTO labels(record_id,label) VALUES(?,?)", [.text(key(record.id)), .text(label)]) }
    }
    private func decodeRecord(_ value: SQLValue) throws -> CaptureRecord {
        guard let text = value.text else { throw JournalError.corruptStore }
        do {
            let record = try JournalJSON.decodeRecord(Data(text.utf8))
            try JournalValidation.record(record, limits: JournalValidation.storedLimits); return record
        } catch { throw JournalError.corruptStore }
    }
    private func decodePhoto(_ value: SQLValue) throws -> PhotoAttachment {
        guard let text = value.text else { throw JournalError.corruptStore }
        do {
            let photo = try JournalJSON.decoder().decode(PhotoAttachment.self, from: Data(text.utf8))
            try JournalValidation.attachment(photo, limits: JournalValidation.storedLimits); return photo
        } catch { throw JournalError.corruptStore }
    }
    func encoded<T: Encodable>(_ value: T) throws -> String { String(decoding: try JournalJSON.encoder().encode(value), as: UTF8.self) }
    private func isInside(_ url: URL, parent: URL) -> Bool { url.path == parent.path || url.path.hasPrefix(parent.path + "/") }
    private func validateDestination(_ destination: URL) throws {
        guard destination.isFileURL else { throw JournalError.unsafePath }
        let parent = destination.deletingLastPathComponent()
        try JournalFiles.directory(parent)
        let canonical = parent.resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent).standardizedFileURL
        guard !isInside(canonical, parent: root), !isInside(root, parent: canonical) else { throw JournalError.unsafePath }
        if FileManager.default.fileExists(atPath: destination.path) { throw JournalError.destinationExists }
        if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil { throw JournalError.unsafePath }
    }

    private static func initialize(_ db: JournalDatabase) throws -> UUID {
        try db.execute("PRAGMA foreign_keys=ON")
        let id: UUID = try db.transaction {
            let version = try db.rows("PRAGMA user_version").first?.first?.integer ?? -1
            let app = try db.rows("PRAGMA application_id").first?.first?.integer ?? -1
            guard (0...2).contains(version) else { throw JournalError.unsupportedVersion }
            if version == 0 {
                guard app == 0, try db.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").isEmpty else { throw JournalError.corruptStore }
                for sql in [
                    "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
                    "CREATE TABLE records(id TEXT PRIMARY KEY,current_revision INTEGER NOT NULL,recorded_ms REAL NOT NULL,timeline_ms REAL NOT NULL,note TEXT,provider TEXT,source_record_id TEXT,UNIQUE(provider,source_record_id))",
                    "CREATE TABLE revisions(record_id TEXT NOT NULL,revision INTEGER NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(record_id,revision),FOREIGN KEY(record_id) REFERENCES records(id) ON DELETE CASCADE)",
                    "CREATE TABLE photos(id TEXT PRIMARY KEY,payload TEXT NOT NULL)",
                    "CREATE TABLE revision_photos(record_id TEXT NOT NULL,revision INTEGER NOT NULL,photo_id TEXT NOT NULL,PRIMARY KEY(record_id,revision,photo_id),FOREIGN KEY(record_id,revision) REFERENCES revisions(record_id,revision) ON DELETE CASCADE,FOREIGN KEY(photo_id) REFERENCES photos(id))",
                    "CREATE TABLE labels(record_id TEXT NOT NULL,label TEXT NOT NULL,PRIMARY KEY(record_id,label),FOREIGN KEY(record_id) REFERENCES records(id) ON DELETE CASCADE)",
                    "CREATE INDEX records_timeline ON records(timeline_ms,id)", "CREATE INDEX records_recorded ON records(recorded_ms,id)",
                    "CREATE INDEX photo_references ON revision_photos(photo_id)",
                    "PRAGMA application_id=\(applicationID)", "PRAGMA user_version=1"
                ] { try db.execute(sql) }
                try db.execute("INSERT INTO metadata(key,value) VALUES('deviceID',?)", [.text(UUID().uuidString.lowercased())])
            } else if app != applicationID { throw JournalError.corruptStore }
            if version < 2 { try initializeSync(db) }
            guard try db.rows("PRAGMA quick_check").first?.first?.text == "ok", try db.rows("PRAGMA foreign_key_check").isEmpty,
                  let value = try db.rows("SELECT value FROM metadata WHERE key='deviceID'").first?.first?.text,
                  let id = UUID(uuidString: value) else { throw JournalError.corruptStore }
            return id
        }
        return id
    }
}

public enum JournalJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder
    }
    static func decodeRecord(_ data: Data) throws -> CaptureRecord {
        try checkRecord(JSONSerialization.jsonObject(with: data))
        return try decoder().decode(CaptureRecord.self, from: data)
    }
    static func decodeBackup(_ data: Data) throws -> JournalBackup {
        let root = try object(JSONSerialization.jsonObject(with: data), keys: ["format", "createdAt", "records", "photos", "deletedRecordIDs", "syncEvidence"])
        guard let records = root["records"] as? [Any], let photos = root["photos"] as? [Any] else { throw JournalError.invalidBackup }
        for value in records {
            let history = try object(value, keys: ["id", "revisions"])
            guard let revisions = history["revisions"] as? [Any] else { throw JournalError.invalidBackup }
            for record in revisions { try checkRecord(record) }
        }
        for photo in photos { try checkPhoto(photo) }
        if let evidence = root["syncEvidence"] {
            guard let operations = evidence as? [Any] else { throw JournalError.invalidBackup }
            for op in operations { try checkSync(op) }
        }
        return try decoder().decode(JournalBackup.self, from: data)
    }
    static func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else { throw JournalError.invalidBackup }
        return object
    }
    private static func checkPhoto(_ value: Any) throws {
        _ = try object(value, keys: ["id", "mimeType", "byteCount", "sha256", "relativePath"])
    }
    static func checkSync(_ value: Any) throws {
        let keys: Set<String> = ["op_id", "record_id", "base", "deleted", "payload"]
        let op = try object(value, keys: keys)
        guard Set(op.keys) == keys else { throw JournalError.invalidBackup }
        if let payload = op["payload"], !(payload is NSNull) { try checkRecord(payload) }
    }
    private static func checkRecord(_ value: Any) throws {
        let record = try object(value, keys: ["schemaVersion", "id", "revision", "recordedAt", "updatedAt", "timeZoneIdentifier", "note", "photos", "occurred", "labels", "source"])
        if let note = record["note"], !(note is String) { throw JournalError.invalidBackup }
        guard let photos = record["photos"] as? [Any], let source = record["source"] else { throw JournalError.invalidBackup }
        for photo in photos { try checkPhoto(photo) }
        let origin = try object(source, keys: ["kind", "deviceID", "provider", "sourceRecordID"])
        for key in ["provider", "sourceRecordID"] {
            if let value = origin[key], !(value is String) { throw JournalError.invalidBackup }
        }
        if let occurred = record["occurred"] {
            let time = try object(occurred, keys: ["start", "end", "timeZoneIdentifier", "precision"])
            if time["end"] is NSNull { throw JournalError.invalidBackup }
        }
    }
}
