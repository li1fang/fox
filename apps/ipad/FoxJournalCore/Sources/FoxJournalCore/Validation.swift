import CryptoKit
import Foundation

enum JournalValidation {
    static let extensions = ["image/jpeg": "jpg", "image/png": "png", "image/heic": "heic"]
    static var storedLimits: JournalLimits {
        var limits = JournalLimits()
        limits.noteBytes = .max; limits.photosPerRecord = .max; limits.photoBytes = .max
        limits.recordPhotoBytes = .max; limits.backupBytes = .max; limits.backupRecords = .max
        return limits
    }
    static func date(_ value: Date) throws {
        guard value.timeIntervalSince1970.isFinite, (-62_135_596_800...253_402_300_799).contains(value.timeIntervalSince1970) else { throw JournalError.invalidInput("date") }
    }
    static func canonical(_ value: Date) -> Date { Date(timeIntervalSince1970: (value.timeIntervalSince1970 * 1000).rounded() / 1000) }
    static func occurrence(_ value: OccurrenceTime?) throws -> OccurrenceTime? {
        guard var value else { return nil }
        try date(value.start); if let end = value.end { try date(end) }
        guard TimeZone(identifier: value.timeZoneIdentifier) != nil, value.end.map({ $0 >= value.start }) ?? true else { throw JournalError.invalidInput("occurrence") }
        value.start = canonical(value.start); value.end = value.end.map(canonical); return value
    }
    static func content(note: String?, photos: [PhotoAttachment], zone: String, labels: [String], limits: JournalLimits) throws {
        guard TimeZone(identifier: zone) != nil, (note?.utf8.count ?? 0) <= limits.noteBytes,
              !(note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) || !photos.isEmpty,
              labels.count <= 24, Set(labels).count == labels.count,
              labels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 }),
              photos.count <= limits.photosPerRecord, Set(photos.map(\.id)).count == photos.count else { throw JournalError.invalidInput("content") }
        var bytes = 0
        for photo in photos {
            try attachment(photo, limits: limits)
            let sum = bytes.addingReportingOverflow(photo.byteCount)
            guard !sum.overflow, sum.partialValue <= limits.recordPhotoBytes else { throw JournalError.invalidInput("photo size") }
            bytes = sum.partialValue
        }
    }
    static func source(_ value: CaptureSource) throws {
        switch value.kind {
        case .user:
            guard value.provider == nil, value.sourceRecordID == nil else { throw JournalError.invalidInput("source") }
        case .external:
            guard let provider = value.provider, !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  provider.utf8.count <= 256, let id = value.sourceRecordID,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 1024 else { throw JournalError.invalidInput("source") }
        }
    }
    static func attachment(_ value: PhotoAttachment, limits: JournalLimits) throws {
        guard let ext = extensions[value.mimeType], value.byteCount > 0, value.byteCount <= limits.photoBytes,
              value.sha256.utf8.count == 64, value.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              value.relativePath == "attachments/\(value.id.uuidString.lowercased()).\(ext)" else { throw JournalError.attachmentIntegrity }
    }
    static func record(_ value: CaptureRecord, limits: JournalLimits) throws {
        guard value.schemaVersion == 1, (1...Int(Int32.max)).contains(value.revision) else { throw JournalError.unsupportedVersion }
        try date(value.recordedAt); try date(value.updatedAt)
        guard value.updatedAt >= value.recordedAt else { throw JournalError.invalidInput("revision date") }
        _ = try occurrence(value.occurred); try source(value.source)
        try content(note: value.note, photos: value.photos, zone: value.timeZoneIdentifier, labels: value.labels, limits: limits)
    }
    static func histories(_ histories: [JournalBackup.History], limits: JournalLimits, enforceBackupLimits: Bool = true) throws -> [UUID: PhotoAttachment] {
        guard (!enforceBackupLimits || histories.count <= limits.backupRecords), Set(histories.map(\.id)).count == histories.count else { throw JournalError.invalidBackup }
        var photos: [UUID: PhotoAttachment] = [:]
        for history in histories {
            guard let first = history.revisions.first else { throw JournalError.invalidBackup }
            for (index, record) in history.revisions.enumerated() {
                try self.record(record, limits: limits)
                guard record.id == history.id, record.revision == index + 1, record.recordedAt == first.recordedAt,
                      record.source == first.source, index == 0 || record.updatedAt >= history.revisions[index - 1].updatedAt else { throw JournalError.invalidBackup }
                for photo in record.photos {
                    if let previous = photos[photo.id], previous != photo { throw JournalError.invalidBackup }
                    photos[photo.id] = photo
                }
            }
        }
        guard enforceBackupLimits else { return photos }
        var bytes = 0
        for photo in photos.values {
            let sum = bytes.addingReportingOverflow(photo.byteCount)
            guard !sum.overflow, sum.partialValue <= limits.backupBytes else { throw JournalError.invalidBackup }
            bytes = sum.partialValue
        }
        return photos
    }
}

enum JournalFiles {
    static let manager = FileManager.default
    static func directory(_ url: URL, create: Bool = false) throws {
        guard url.isFileURL else { throw JournalError.unsafePath }
        if !manager.fileExists(atPath: url.path), create { try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        guard try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { throw JournalError.unsafePath }
    }
    static func regularFile(_ url: URL, maximum: Int) throws -> Int {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size >= 0, size <= maximum else { throw JournalError.unsafePath }
        return size
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func verify(_ url: URL, photo: PhotoAttachment, limits: JournalLimits) throws {
        try JournalValidation.attachment(photo, limits: limits)
        guard try regularFile(url, maximum: limits.photoBytes) == photo.byteCount else { throw JournalError.attachmentIntegrity }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), bytes = 0
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            bytes += chunk.count; guard bytes <= photo.byteCount else { throw JournalError.attachmentIntegrity }; hash.update(data: chunk)
        }
        guard bytes == photo.byteCount, hash.finalize().map({ String(format: "%02x", $0) }).joined() == photo.sha256 else { throw JournalError.attachmentIntegrity }
    }
    static func protect(_ url: URL, directory: Bool = false) throws {
        try manager.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
