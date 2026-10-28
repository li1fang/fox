import Foundation

public struct JournalSyncOperation: Codable, Equatable, Sendable {
    public let op_id: String
    public let record_id: String
    public let base: String?
    public let deleted: Bool
    public let payload: CaptureRecord?
    public init(op_id: String, record_id: String, base: String?, deleted: Bool, payload: CaptureRecord?) {
        self.op_id = op_id; self.record_id = record_id; self.base = base; self.deleted = deleted; self.payload = payload
    }
    enum CodingKeys: String, CodingKey { case op_id, record_id, base, deleted, payload }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op_id, forKey: .op_id); try c.encode(record_id, forKey: .record_id)
        try c.encode(base, forKey: .base); try c.encode(deleted, forKey: .deleted); try c.encode(payload, forKey: .payload)
    }
    public func validate() throws {
        guard !op_id.isEmpty, op_id.utf8.count <= 256, base?.utf8.count ?? 0 <= 256,
              let id = UUID(uuidString: record_id), record_id == id.uuidString.lowercased(),
              deleted ? payload == nil : payload?.id == id else { throw JournalError.invalidInput("sync operation") }
        if let payload { try JournalValidation.record(payload, limits: JournalValidation.storedLimits) }
    }
}

public struct JournalSyncReceipt: Codable, Sendable {
    public var status: String
    public var seq: Int?
    public var revision: String?
    public var head: JournalSyncOperation?
    public init(status: String, seq: Int? = nil, revision: String? = nil, head: JournalSyncOperation? = nil) {
        self.status = status; self.seq = seq; self.revision = revision; self.head = head
    }
    public static func decode(_ data: Data) throws -> Self {
        let value = try JournalJSON.object(JSONSerialization.jsonObject(with: data), keys: ["status", "seq", "revision", "head"])
        if let head = value["head"], !(head is NSNull) { try JournalJSON.checkSync(head) }
        return try JournalJSON.decoder().decode(Self.self, from: data)
    }
}
public struct JournalSyncEvent: Codable, Sendable {
    public var seq: Int
    public var operation: JournalSyncOperation
    public init(seq: Int, operation: JournalSyncOperation) { self.seq = seq; self.operation = operation }
}
public struct JournalSyncPage: Codable, Sendable {
    public var vault: String
    public var events: [JournalSyncEvent]
    public var cursor: Int
    public var more: Bool
    public init(vault: String, events: [JournalSyncEvent], cursor: Int, more: Bool) {
        self.vault = vault; self.events = events; self.cursor = cursor; self.more = more
    }
    public static func decode(_ data: Data) throws -> Self {
        let value = try JournalJSON.object(JSONSerialization.jsonObject(with: data), keys: ["vault", "events", "cursor", "more"])
        guard let events = value["events"] as? [Any] else { throw JournalError.invalidInput("events") }
        for value in events {
            let event = try JournalJSON.object(value, keys: ["seq", "operation"])
            guard let op = event["operation"] else { throw JournalError.invalidInput("operation") }
            try JournalJSON.checkSync(op)
        }
        return try JournalJSON.decoder().decode(Self.self, from: data)
    }
}
public struct JournalSyncStatus: Sendable {
    public let vault: String?
    public let cursor: Int
    public let pending: Int
    public let conflicts: Int
    public let blocked: Int
}
public struct JournalSyncConflict: Identifiable, Sendable {
    public let id: UUID
    public let local: CaptureRecord?
    public let remote: CaptureRecord?
    public let remoteDeleted: Bool
}

extension LocalJournalRepository {
    static func initializeSync(_ db: JournalDatabase) throws {
        for sql in [
            "CREATE TABLE journal_tombstones(id TEXT PRIMARY KEY)",
            "CREATE TABLE sync_outbox(id TEXT PRIMARY KEY,record_id TEXT NOT NULL,operation TEXT NOT NULL,state TEXT NOT NULL)",
            "CREATE TABLE sync_events(seq INTEGER PRIMARY KEY,operation TEXT NOT NULL)",
            "CREATE TABLE sync_heads(id TEXT PRIMARY KEY,operation TEXT NOT NULL,seq INTEGER NOT NULL)",
            "CREATE TABLE sync_conflict_heads(id TEXT PRIMARY KEY,required_head TEXT NOT NULL)",
            "CREATE TABLE sync_archive(id TEXT PRIMARY KEY,operation TEXT NOT NULL)",
            "CREATE TABLE sync_downloads(photo_id TEXT PRIMARY KEY,FOREIGN KEY(photo_id) REFERENCES photos(id))",
            "CREATE TABLE sync_photo_refs(op_id TEXT NOT NULL,photo_id TEXT NOT NULL,PRIMARY KEY(op_id,photo_id),FOREIGN KEY(photo_id) REFERENCES photos(id))",
            "PRAGMA user_version=2"
        ] { try db.execute(sql) }
    }

    public func enableSync(vault: String) throws {
        try locked { try transaction {
            guard !vault.isEmpty, vault.utf8.count <= 256 else { throw JournalError.invalidInput("vault") }
            if let previous = try syncVault() {
                guard previous == vault else { throw JournalError.captureConflict }; return
            }
            try db.execute("INSERT INTO metadata VALUES('syncVault',?)", [.text(vault)])
            try db.execute("INSERT INTO metadata VALUES('syncCursor','0')")
            for row in try db.rows("SELECT id FROM records ORDER BY id") {
                guard let value = row[0].text, let id = UUID(uuidString: value) else { throw JournalError.corruptStore }
                for r in try historyUnlocked(id) { try enqueueSync(r.id, payload: r) }
                if try isTombstone(id) { try enqueueSync(id, payload: nil) }
            }
            try checkpoint?(.beforeCommit)
        } }
    }

    func syncVault() throws -> String? { try db.rows("SELECT value FROM metadata WHERE key='syncVault'").first?.first?.text }
    func syncCursor() throws -> Int {
        guard let value = try db.rows("SELECT value FROM metadata WHERE key='syncCursor'").first?.first?.text else { return 0 }
        guard let cursor = Int(value), cursor >= 0 else { throw JournalError.corruptStore }; return cursor
    }
    func isTombstone(_ id: UUID) throws -> Bool { !(try db.rows("SELECT 1 FROM journal_tombstones WHERE id=?", [.text(key(id))])).isEmpty }
    func operation(_ row: [SQLValue]) throws -> JournalSyncOperation {
        guard let value = row.first?.text else { throw JournalError.corruptStore }
        let op = try JournalJSON.decoder().decode(JournalSyncOperation.self, from: Data(value.utf8))
        try op.validate(); return op
    }
    func retainSyncPhotos(_ op: JournalSyncOperation) throws {
        for p in op.payload?.photos ?? [] {
            try db.execute("INSERT OR IGNORE INTO sync_photo_refs VALUES(?,?)", [.text(op.op_id), .text(key(p.id))])
        }
    }
    func enqueueSync(_ id: UUID, payload: CaptureRecord?) throws {
        guard try syncVault() != nil else { return }
        let queued = try db.rows("SELECT operation FROM sync_outbox WHERE record_id=? AND state IN ('pending','conflict','blocked') ORDER BY rowid DESC LIMIT 1", [.text(key(id))]).first
        let head = try db.rows("SELECT operation FROM sync_heads WHERE id=?", [.text(key(id))]).first
        let base = try (queued ?? head).map(operation)?.op_id
        let op = JournalSyncOperation(op_id: key(UUID()), record_id: key(id), base: base, deleted: payload == nil, payload: payload)
        let hasConflict = !(try db.rows("SELECT 1 FROM sync_outbox WHERE record_id=? AND state='conflict' LIMIT 1", [.text(key(id))])).isEmpty
        let blocked = !(try db.rows("SELECT 1 FROM sync_outbox WHERE record_id=? AND state='blocked' LIMIT 1", [.text(key(id))])).isEmpty
        try db.execute("INSERT INTO sync_outbox VALUES(?,?,?,?)", [.text(op.op_id), .text(key(id)), .text(try encoded(op)), .text(hasConflict ? "conflict" : blocked ? "blocked" : "pending")])
        try retainSyncPhotos(op)
    }
    public func syncStatus() throws -> JournalSyncStatus {
        try locked { try db.transaction {
            let pending = try db.rows("SELECT COUNT(*) FROM sync_outbox WHERE state='pending'")[0][0].integer ?? 0
            let conflicts = try db.rows("SELECT COUNT(*) FROM sync_outbox WHERE state='conflict'")[0][0].integer ?? 0
            let blocked = try db.rows("SELECT COUNT(*) FROM sync_outbox WHERE state='blocked'")[0][0].integer ?? 0
            return JournalSyncStatus(vault: try syncVault(), cursor: try syncCursor(), pending: Int(pending), conflicts: Int(conflicts), blocked: Int(blocked))
        } }
    }
    public func syncPending() throws -> [JournalSyncOperation] {
        try locked { try db.rows("SELECT operation FROM sync_outbox WHERE state='pending' ORDER BY rowid").map(operation) }
    }
    public func syncBlockOversizedRecord(_ id: String) throws {
        try locked { try transaction {
            try db.execute("UPDATE sync_outbox SET state='blocked' WHERE record_id=? AND state='pending'", [.text(id)])
        } }
    }
    public func syncStorePhoto(_ photo: PhotoAttachment, data: Data) throws {
        try locked { try transaction {
            if let existing = try photoDescriptor(photo.id) {
                guard existing == photo else { throw JournalError.attachmentIntegrity }; try verifyPhoto(existing)
            } else { try writePhoto(data, descriptor: photo) }
            // Interrupted downloads survive restart without advancing the remote cursor.
            try db.execute("INSERT OR IGNORE INTO sync_downloads VALUES(?)", [.text(key(photo.id))])
            try checkpoint?(.beforeCommit)
        } }
    }
    private func updateSyncHead(_ op: JournalSyncOperation, seq: Int) throws -> Bool {
        if let previous = try db.rows("SELECT operation,seq FROM sync_heads WHERE id=?", [.text(op.record_id)]).first {
            guard let oldSeq = previous[1].integer else { throw JournalError.corruptStore }
            if oldSeq > seq { return false }
            if oldSeq == seq {
                guard try operation(previous) == op else { throw JournalError.captureConflict }; return false
            }
        }
        try db.execute("INSERT OR REPLACE INTO sync_heads VALUES(?,?,?)", [.text(op.record_id), .text(try encoded(op)), .integer(Int64(seq))])
        return true
    }
    public func syncAcknowledge(_ op: JournalSyncOperation, receipt: JournalSyncReceipt) throws {
        try locked { try transaction {
            guard let row = try db.rows("SELECT operation FROM sync_outbox WHERE id=?", [.text(op.op_id)]).first,
                  try operation(row) == op else { throw JournalError.captureConflict }
            if receipt.status == "accepted" {
                guard receipt.revision == op.op_id, let seq = receipt.seq, seq > 0 else { throw JournalError.invalidInput("ack") }
                try db.execute("UPDATE sync_outbox SET state='accepted' WHERE id=?", [.text(op.op_id)])
                // Accepted head supplies the base for edits made after the network acknowledgement.
                // A subsequent pull remains authoritative and advances the cursor independently.
                _ = try updateSyncHead(op, seq: seq)
            } else if receipt.status == "conflict" {
                guard let head = receipt.head else { throw JournalError.invalidInput("missing conflict head") }
                try head.validate(); guard head.record_id == op.record_id else { throw JournalError.invalidInput("conflict head") }
                try db.execute("INSERT OR REPLACE INTO sync_conflict_heads VALUES(?,?)", [.text(op.record_id), .text(head.op_id)])
                try db.execute("UPDATE sync_outbox SET state='conflict' WHERE record_id=? AND state='pending'", [.text(op.record_id)])
            } else { throw JournalError.invalidInput("ack status") }
            try checkpoint?(.beforeCommit)
        } }
    }

    public func syncApply(_ page: JournalSyncPage, expectedCursor: Int, photos: [UUID: Data]) throws {
        try locked { try transaction {
            guard try syncVault() == page.vault, try syncCursor() == expectedCursor, page.events.count <= 50,
                  !page.events.isEmpty || !page.more else { throw JournalError.invalidInput("sync page") }
            var last = expectedCursor
            for event in page.events {
                guard last < Int.max, event.seq == last + 1 else { throw JournalError.invalidInput("sync sequence") }
                try event.operation.validate(); last = event.seq
                let op = event.operation
                for p in op.payload?.photos ?? [] {
                    if let existing = try photoDescriptor(p.id) {
                        guard existing == p else { throw JournalError.attachmentIntegrity }; try verifyPhoto(existing)
                    } else {
                        guard let data = photos[p.id] else { throw JournalError.attachmentIntegrity }
                        try writePhoto(data, descriptor: p)
                    }
                }
                try retainSyncPhotos(op)
                for p in op.payload?.photos ?? [] { try db.execute("DELETE FROM sync_downloads WHERE photo_id=?", [.text(key(p.id))]) }
                try db.execute("INSERT INTO sync_events VALUES(?,?)", [.integer(Int64(event.seq)), .text(try encoded(op))])
                let advanced = try updateSyncHead(op, seq: event.seq)
                let local = try db.rows("SELECT state FROM sync_outbox WHERE record_id=? AND state IN ('pending','conflict','blocked') LIMIT 1", [.text(op.record_id)])
                let own = try db.rows("SELECT 1 FROM sync_outbox WHERE id=?", [.text(op.op_id)])
                if advanced && local.isEmpty && own.isEmpty { try projectRemote(op) }
            }
            guard page.cursor == last else { throw JournalError.invalidInput("page cursor") }
            try db.execute("UPDATE metadata SET value=? WHERE key='syncCursor'", [.text(String(last))])
            try checkpoint?(.beforeCommit)
        } }
    }

    // Immutable wire operations retain the exact remote payload. Journal revisions are a
    // local chronological projection, not global revisions or inferred original history.
    func projectRemote(_ op: JournalSyncOperation) throws {
        guard let id = UUID(uuidString: op.record_id) else { throw JournalError.invalidInput("record ID") }
        if op.deleted {
            try db.execute("INSERT OR IGNORE INTO journal_tombstones VALUES(?)", [.text(key(id))]); return
        }
        guard let raw = op.payload else { throw JournalError.invalidInput("payload") }
        let previous = try getUnlocked(id, includeDeleted: true)
        if let previous {
            guard previous.recordedAt == raw.recordedAt, previous.source == raw.source else { throw JournalError.captureConflict }
        }
        let record = CaptureRecord(schemaVersion: 1, id: id, revision: (previous?.revision ?? 0) + 1,
            recordedAt: raw.recordedAt, updatedAt: max(previous?.updatedAt ?? raw.updatedAt, raw.updatedAt),
            timeZoneIdentifier: raw.timeZoneIdentifier, note: raw.note, photos: raw.photos, occurred: raw.occurred, labels: raw.labels, source: raw.source)
        try JournalValidation.record(record, limits: JournalValidation.storedLimits)
        if previous == nil { try insertRecord(record) }
        else {
            try db.execute("UPDATE records SET current_revision=?,timeline_ms=?,note=? WHERE id=?", [.integer(Int64(record.revision)), .number(record.timelineAt.timeIntervalSince1970 * 1000), record.note.map(SQLValue.text) ?? .null, .text(key(id))])
        }
        try insertRevision(record)
        try db.execute("DELETE FROM journal_tombstones WHERE id=?", [.text(key(id))])
    }

    public func syncConflicts() throws -> [JournalSyncConflict] {
        try locked { try db.transaction {
            try db.rows("SELECT DISTINCT record_id FROM sync_outbox WHERE state='conflict'").compactMap { row in
                guard let text = row[0].text, try conflictReady(text) else { return nil }
                guard let id = UUID(uuidString: text),
                      let head = try db.rows("SELECT operation FROM sync_heads WHERE id=?", [.text(text)]).first else { throw JournalError.corruptStore }
                let op = try operation(head)
                return JournalSyncConflict(id: id, local: try getUnlocked(id), remote: op.payload, remoteDeleted: op.deleted)
            }
        } }
    }
    public func resolveSyncConflict(_ id: UUID, keepLocal: Bool) throws {
        try locked { try transaction {
            guard !(try db.rows("SELECT 1 FROM sync_outbox WHERE record_id=? AND state='conflict'", [.text(key(id))])).isEmpty,
                  try conflictReady(key(id)),
                  let row = try db.rows("SELECT operation FROM sync_heads WHERE id=?", [.text(key(id))]).first else { throw JournalError.notFound }
            let head = try operation(row)
            try db.execute("UPDATE sync_outbox SET state='resolved' WHERE record_id=? AND state='conflict'", [.text(key(id))])
            if keepLocal { try enqueueSync(id, payload: getUnlocked(id)) }
            else { try projectRemote(head) }
            try checkpoint?(.beforeCommit)
        } }
    }
    private func conflictReady(_ id: String) throws -> Bool {
        guard let expected = try db.rows("SELECT required_head FROM sync_conflict_heads WHERE id=?", [.text(id)]).first?.first?.text else { return false }
        // A conflict receipt is not evidence that remote attachments were fetched.
        // Only verified event history (or an already accepted local head) unlocks selection.
        for row in try db.rows("SELECT operation FROM sync_events UNION ALL SELECT operation FROM sync_outbox WHERE state='accepted'") {
            if try operation(row).op_id == expected { return true }
        }
        return false
    }
    func syncEvidence() throws -> [JournalSyncOperation] {
        var result: [String: JournalSyncOperation] = [:]
        for table in ["sync_outbox", "sync_events", "sync_archive"] {
            for row in try db.rows("SELECT operation FROM \(table)") {
                let op = try operation(row)
                if let old = result[op.op_id], old != op { throw JournalError.corruptStore }
                result[op.op_id] = op
            }
        }
        return result.values.sorted { $0.op_id < $1.op_id }
    }
}
