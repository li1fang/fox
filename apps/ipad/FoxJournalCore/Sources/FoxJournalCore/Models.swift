import Foundation

public enum JournalError: Error, Equatable {
    case invalidInput(String), notFound, revisionConflict, captureConflict, backupConflict
    case corruptStore, unsupportedVersion, invalidBackup, attachmentIntegrity
    case unsafePath, destinationExists, ioFailure, sqlite(String)
}

public struct OccurrenceTime: Codable, Equatable, Sendable {
    public enum Precision: String, Codable, Sendable { case exact, approximate, day }
    public var start: Date
    public var end: Date?
    public var timeZoneIdentifier: String
    public var precision: Precision

    public init(start: Date, end: Date? = nil, timeZoneIdentifier: String, precision: Precision = .exact) {
        self.start = start; self.end = end; self.timeZoneIdentifier = timeZoneIdentifier; self.precision = precision
    }
}

public struct CaptureSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, external }
    public var kind: Kind
    public var deviceID: UUID
    public var provider: String?
    public var sourceRecordID: String?

    public init(kind: Kind = .user, deviceID: UUID, provider: String? = nil, sourceRecordID: String? = nil) {
        self.kind = kind; self.deviceID = deviceID; self.provider = provider; self.sourceRecordID = sourceRecordID
    }
}

public struct PhotoInput: Sendable {
    public var data: Data
    public var mimeType: String
    public init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }
}

public struct CaptureDraft: Sendable {
    public var id: UUID
    public var recordedAt: Date
    public var timeZoneIdentifier: String
    public var note: String?
    public var photos: [PhotoInput]
    public var occurred: OccurrenceTime?
    public var labels: [String]
    public var source: CaptureSource?

    public init(id: UUID = UUID(), recordedAt: Date = Date(), timeZoneIdentifier: String = TimeZone.current.identifier,
                note: String? = nil, photos: [PhotoInput] = [], occurred: OccurrenceTime? = nil,
                labels: [String] = [], source: CaptureSource? = nil) {
        self.id = id; self.recordedAt = recordedAt; self.timeZoneIdentifier = timeZoneIdentifier
        self.note = note; self.photos = photos; self.occurred = occurred; self.labels = labels; self.source = source
    }
}

public struct PhotoAttachment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var mimeType: String
    public var byteCount: Int
    public var sha256: String
    public var relativePath: String
}

public struct CaptureRecord: Codable, Equatable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let revision: Int
    public let recordedAt: Date
    public let updatedAt: Date
    public let timeZoneIdentifier: String
    public let note: String?
    public let photos: [PhotoAttachment]
    public let occurred: OccurrenceTime?
    public let labels: [String]
    public let source: CaptureSource
    public var timelineAt: Date { occurred?.start ?? recordedAt }
}

public struct CaptureEdit: Sendable {
    public var note: String?
    public var occurred: OccurrenceTime?
    public var timeZoneIdentifier: String
    public var labels: [String]
    public var keepPhotoIDs: [UUID]
    public var newPhotos: [PhotoInput]

    public init(from record: CaptureRecord) {
        note = record.note; occurred = record.occurred; timeZoneIdentifier = record.timeZoneIdentifier
        labels = record.labels; keepPhotoIDs = record.photos.map(\.id); newPhotos = []
    }
}

public struct JournalQuery: Sendable {
    public enum TimeBasis: Sendable { case timeline, recorded }
    public var text: String?
    public var label: String?
    public var from: Date?
    public var before: Date?
    public var timeBasis: TimeBasis
    public var limit: Int
    public var offset: Int
    public init(text: String? = nil, label: String? = nil, from: Date? = nil, before: Date? = nil,
                timeBasis: TimeBasis = .timeline, limit: Int = 50, offset: Int = 0) {
        self.text = text; self.label = label; self.from = from; self.before = before
        self.timeBasis = timeBasis; self.limit = limit; self.offset = offset
    }
}

public struct JournalLimits: Sendable {
    public var noteBytes = 131_072
    public var photosPerRecord = 12
    public var photoBytes = 52_428_800
    public var recordPhotoBytes = 209_715_200
    public var backupBytes = 1_073_741_824
    public var backupRecords = 100_000
    public init() {}
}

public struct CleanupReport: Equatable, Sendable {
    public var pendingPhotoIDs: [UUID]
    public var unrecognizedFiles: [String]
    public var failure: String? = nil
    public var complete: Bool { pendingPhotoIDs.isEmpty && unrecognizedFiles.isEmpty && failure == nil }
}

public struct RestoreReceipt: Equatable, Sendable {
    public let inserted: Int
    public let unchanged: Int
}

public struct JournalBackup: Codable, Equatable, Sendable {
    public struct History: Codable, Equatable, Sendable {
        public var id: UUID
        public var revisions: [CaptureRecord]
    }
    public var format: String
    public var createdAt: Date
    public var records: [History]
    public var photos: [PhotoAttachment]
}

package enum JournalCheckpoint { case photoWritten, beforeCommit, beforePhotoRemoval, backupPhotoCopied }
