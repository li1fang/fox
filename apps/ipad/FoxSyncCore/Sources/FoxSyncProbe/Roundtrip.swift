import Foundation
import FoxJournalCore
import FoxSyncCore

private actor LoseOneAcknowledgement: SyncRPC {
    let client: SyncHTTPSClient
    var lose = true
    init(_ client: SyncHTTPSClient) { self.client = client }
    func send(header: Data, body: Data) async throws -> Data {
        let reply = try await client.send(header: header, body: body)
        let request = try JSONSerialization.jsonObject(with: header) as? [String: Any]
        if lose, request?["action"] as? String == "push" { lose = false; throw URLError(.networkConnectionLost) }
        return reply
    }
}

private final class ProbeCredentials: SyncCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SyncPairing] = [:]
    func load(account: String) throws -> SyncPairing? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func save(_ pairing: SyncPairing, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { throw SyncClientError.alreadyPaired }; values[account] = pairing
    }
}

func nativeRoundtrip(config: URL, output: URL) async throws {
    struct Settings: Decodable { let endpoint: URL; let certificatePath: String; let vault: String; let invitationPaths: [String] }
    let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: config))
    guard settings.invitationPaths.count == 2, !FileManager.default.fileExists(atPath: output.path) else { throw SyncClientError.invalidPairing }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let certificate = try Data(contentsOf: URL(fileURLWithPath: settings.certificatePath))
    let a = try LocalJournalRepository(directory: output.appendingPathComponent("peer-a"))
    let b = try LocalJournalRepository(directory: output.appendingPathComponent("peer-b"))
    let credentials = ProbeCredentials()
    let invites = try settings.invitationPaths.map { try SyncInvitation.decode(Data(contentsOf: URL(fileURLWithPath: $0))) }
    _ = try await JournalSyncEngine.pair(repository: a, invitation: invites[0], credentials: credentials, name: "native-synthetic-a")
    let eb = try await JournalSyncEngine.pair(repository: b, invitation: invites[1], credentials: credentials, name: "native-synthetic-b")
    guard let firstPair = try credentials.load(account: a.deviceID.uuidString) else { throw SyncClientError.missingCredentials }
    let transport = try SyncHTTPSClient(endpoint: settings.endpoint, certificate: certificate)
    let ea = JournalSyncEngine(repository: a, rpc: LoseOneAcknowledgement(transport), vault: settings.vault, token: firstPair.token)
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jQn0AAAAASUVORK5CYII=")!
    let original = try a.record(.init(note: "native synthetic original", photos: [.init(data: png, mimeType: "image/png")]))
    var lost = false
    do { _ = try await ea.run() } catch let error as URLError where error.code == .networkConnectionLost { lost = true }
    guard lost, try a.syncStatus().pending == 1 else { throw SyncClientError.invalidReply }
    _ = try await ea.run(); _ = try await eb.run()
    guard let received = try b.get(original.id), try b.photoData(original.photos[0].id) == png else { throw SyncClientError.invalidReply }
    var left = CaptureEdit(from: original); left.note = "native left"
    _ = try a.revise(original.id, expectedRevision: original.revision, edit: left)
    var right = CaptureEdit(from: received); right.note = "native right"
    _ = try b.revise(original.id, expectedRevision: received.revision, edit: right)
    _ = try await ea.run(); _ = try await eb.run()
    guard try b.syncStatus().conflicts == 1, try b.get(original.id)?.note == "native right" else { throw SyncClientError.invalidReply }
    try b.resolveSyncConflict(original.id, keepLocal: true)
    _ = try await eb.run(); _ = try await ea.run()
    guard let current = try a.get(original.id), current.note == "native right" else { throw SyncClientError.invalidReply }
    _ = try a.delete(original.id, expectedRevision: current.revision)
    _ = try await ea.run(); _ = try await eb.run()
    guard try b.get(original.id) == nil, try b.photoData(original.photos[0].id) == png,
          try b.history(original.id).contains(where: { $0.note == "native right" }) else { throw SyncClientError.invalidReply }
    let backup = output.appendingPathComponent("backup")
    _ = try b.exportBackup(to: backup)
    let restored = try LocalJournalRepository(directory: output.appendingPathComponent("restored"))
    _ = try restored.restoreBackup(from: backup)
    guard try restored.get(original.id) == nil, try restored.photoData(original.photos[0].id) == png else { throw SyncClientError.invalidReply }
    let receipt: [String: Any] = ["nativeHTTPSRoundtrip": true, "nativePairingClaim": true, "lostAcknowledgementRetry": true, "conflictResolved": true,
        "tombstoneAndPhotoRetained": true, "backupRestored": true, "deviceExecuted": false, "realRecordsUsed": false]
    try JSONSerialization.data(withJSONObject: receipt, options: .prettyPrinted).write(to: output.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
    print("native_sync_roundtrip_passed")
}
