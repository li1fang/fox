import Foundation
import FoxJournalCore

public protocol SyncRPC: Sendable {
    func send(header: Data, body: Data) async throws -> Data
}
extension SyncHTTPSClient: SyncRPC {}
public enum SyncClientError: Error { case busy, invalidPairing, alreadyPaired, wireLimit, invalidReply, missingCredentials }

public struct SyncInvitation: Codable, Sendable {
    public let schema: String
    public let endpoint: URL
    public let vault: String
    public let certificate: Data
    public let code: String
    public let expiresAt: Date
    public static func decode(_ bytes: Data, now: Date = Date()) throws -> SyncInvitation {
        guard bytes.count <= 16_384 else { throw SyncClientError.invalidPairing }
        let invitation = try JournalJSON.decoder().decode(Self.self, from: bytes)
        guard invitation.schema == "fox.pairing.v1", !invitation.vault.isEmpty, invitation.vault.count <= 256,
              !invitation.code.isEmpty, invitation.code.count <= 256, invitation.expiresAt > now else { throw SyncClientError.invalidPairing }
        _ = try SyncHTTPSClient(endpoint: invitation.endpoint, certificate: invitation.certificate)
        return invitation
    }
}
public struct SyncPairing: Codable, Sendable {
    public let endpoint: URL
    public let certificate: Data
    public let vault: String
    public let device: String
    public let token: String
    public init(endpoint: URL, certificate: Data, vault: String, device: String, token: String) {
        self.endpoint = endpoint; self.certificate = certificate; self.vault = vault; self.device = device; self.token = token
    }
}
public protocol SyncCredentialStore: Sendable {
    func load(account: String) throws -> SyncPairing?
    func save(_ pairing: SyncPairing, account: String) throws
}

public actor JournalSyncEngine {
    private let repository: LocalJournalRepository
    private let rpc: any SyncRPC
    private let vault: String
    private let token: String
    private var running = false
    public init(repository: LocalJournalRepository, rpc: any SyncRPC, vault: String, token: String) {
        self.repository = repository; self.rpc = rpc; self.vault = vault; self.token = token
    }
    public static func paired(repository: LocalJournalRepository, credentials: any SyncCredentialStore, rpc: (any SyncRPC)? = nil) throws -> JournalSyncEngine? {
        guard let pairing = try credentials.load(account: repository.deviceID.uuidString) else { return nil }
        let transport: any SyncRPC = try rpc ?? SyncHTTPSClient(endpoint: pairing.endpoint, certificate: pairing.certificate)
        try repository.enableSync(vault: pairing.vault)
        return JournalSyncEngine(repository: repository, rpc: transport, vault: pairing.vault, token: pairing.token)
    }
    public static func pair(repository: LocalJournalRepository, invitation: SyncInvitation,
                            credentials: any SyncCredentialStore, name: String) async throws -> JournalSyncEngine {
        guard try credentials.load(account: repository.deviceID.uuidString) == nil else { throw SyncClientError.alreadyPaired }
        let status = try repository.syncStatus()
        guard status.vault == nil || status.vault == invitation.vault else { throw SyncClientError.invalidPairing }
        let transport = try SyncHTTPSClient(endpoint: invitation.endpoint, certificate: invitation.certificate)
        let data = try await transport.send(header: wire(["action": "claim", "code": invitation.code, "name": name]), body: Data())
        struct Claim: Decodable { let vault: String; let device: String; let token: String }
        let claim = try JSONDecoder().decode(Claim.self, from: data)
        guard claim.vault == invitation.vault, !claim.token.isEmpty, claim.token.count <= 256, UUID(uuidString: claim.device) != nil else { throw SyncClientError.invalidReply }
        let pairing = SyncPairing(endpoint: invitation.endpoint, certificate: invitation.certificate,
                                  vault: claim.vault, device: claim.device, token: claim.token)
        // Save the non-replayable claim before enabling the transactional queue.
        // If migration fails, the same credential can be recovered on next launch.
        try credentials.save(pairing, account: repository.deviceID.uuidString)
        try repository.enableSync(vault: claim.vault)
        return JournalSyncEngine(repository: repository, rpc: transport, vault: claim.vault, token: claim.token)
    }
    public func run() async throws -> JournalSyncStatus {
        guard !running else { throw SyncClientError.busy }
        running = true; defer { running = false }
        guard try repository.syncStatus().vault == vault else { throw SyncClientError.invalidPairing }
        for op in try repository.syncPending() {
            try Task.checkCancellation()
            // A preceding operation can mark this same-record chain conflicted.
            guard try repository.syncPending().contains(where: { $0.op_id == op.op_id }) else { continue }
            let object = try JSONSerialization.jsonObject(with: JournalJSON.encoder().encode(op))
            let conservativeHeader = try JSONSerialization.data(withJSONObject: ["action": "push", "token": String(repeating: "x", count: 256), "operation": object], options: [.prettyPrinted, .sortedKeys])
            if conservativeHeader.count >= 65_536 || (op.payload?.photos.contains(where: { $0.byteCount > 25 * 1024 * 1024 }) ?? false) {
                try repository.syncBlockOversizedRecord(op.record_id); continue
            }
            let header = try Self.wire(["action": "push", "token": token, "operation": object])
            for photo in op.payload?.photos ?? [] {
                guard photo.byteCount <= 25 * 1024 * 1024 else { throw SyncClientError.wireLimit }
                let data = try repository.photoData(photo.id)
                _ = try await rpc.send(header: Self.wire(["action": "put-photo", "token": token, "photo": Self.object(photo)]), body: data)
            }
            let reply = try await rpc.send(header: header, body: Data())
            let receipt = try JournalSyncReceipt.decode(reply)
            try repository.syncAcknowledge(op, receipt: receipt)
        }
        var pages = 0
        while true {
            try Task.checkCancellation()
            let cursor = try repository.syncStatus().cursor
            let reply = try await rpc.send(header: Self.wire(["action": "pull", "token": token, "cursor": cursor, "limit": 1]), body: Data())
            let page = try JournalSyncPage.decode(reply)
            guard page.vault == vault, page.events.count <= 1 else { throw SyncClientError.invalidReply }
            for event in page.events {
                try event.operation.validate()
                for p in event.operation.payload?.photos ?? [] {
                    if (try? repository.photoData(p.id)) != nil { continue }
                    guard p.byteCount <= 25 * 1024 * 1024 else { throw SyncClientError.wireLimit }
                    let data = try await rpc.send(header: Self.wire(["action": "get-photo", "token": token, "photo": Self.object(p)]), body: Data())
                    try repository.syncStorePhoto(p, data: data)
                }
            }
            try repository.syncApply(page, expectedCursor: cursor, photos: [:])
            pages += 1
            if !page.more { break }
            if pages >= 1000 { throw SyncClientError.wireLimit }
        }
        return try repository.syncStatus()
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JournalJSON.encoder().encode(value))
    }
    private static func wire(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        guard data.count < 65_536 else { throw SyncClientError.wireLimit }; return data
    }
}
