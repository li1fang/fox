import Foundation
import FoxJournalCore

#if os(macOS)
import Darwin
guard CommandLine.arguments.count == 2 else { exit(64) }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard root.lastPathComponent.hasPrefix("fox-journal-test-") else { exit(64) }
let repository = try LocalJournalRepository(directory: root, checkpoint: { point in
    if case .photoWritten = point { _exit(86) }
})
_ = try repository.record(CaptureDraft(note: "uncommitted crash fixture", photos: [PhotoInput(data: Data([1, 2, 3]), mimeType: "image/png")]))
exit(65)
#endif
