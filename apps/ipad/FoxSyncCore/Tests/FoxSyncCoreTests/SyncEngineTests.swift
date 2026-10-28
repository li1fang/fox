import Foundation
import XCTest
import FoxJournalCore
@testable import FoxSyncCore

private actor FakeVault: SyncRPC {
    var events: [JournalSyncEvent] = []
    var blobs: [UUID: Data] = [:]
    var receipts: [String: JournalSyncReceipt] = [:]
    var loseReply = false
    func loseNextReply() { loseReply = true }
    func send(header: Data, body: Data) async throws -> Data {
        let req = try JSONSerialization.jsonObject(with: header) as! [String: Any]
        let encoder = JournalJSON.encoder()
        switch req["action"] as? String {
        case "put-photo":
            let photo = try JournalJSON.decoder().decode(PhotoAttachment.self, from: JSONSerialization.data(withJSONObject: req["photo"]!))
            blobs[photo.id] = body; return Data("{}".utf8)
        case "get-photo":
            let photo = try JournalJSON.decoder().decode(PhotoAttachment.self, from: JSONSerialization.data(withJSONObject: req["photo"]!))
            return blobs[photo.id]!
        case "pull":
            let cursor = req["cursor"] as! Int
            let page = Array(events.dropFirst(cursor).prefix(req["limit"] as? Int ?? 50))
            let last = page.last?.seq ?? cursor
            return try encoder.encode(JournalSyncPage(vault: "vault", events: page, cursor: last, more: last < events.count))
        case "push":
            let op = try JournalJSON.decoder().decode(JournalSyncOperation.self, from: JSONSerialization.data(withJSONObject: req["operation"]!))
            if let old = receipts[op.op_id] { return try encoder.encode(old) }
            let head = events.last { $0.operation.record_id == op.record_id }?.operation
            let receipt: JournalSyncReceipt
            if op.base == head?.op_id {
                events.append(.init(seq: events.count + 1, operation: op))
                receipt = .init(status: "accepted", seq: events.count, revision: op.op_id)
            } else { receipt = .init(status: "conflict", head: head) }
            receipts[op.op_id] = receipt
            if loseReply { loseReply = false; throw URLError(.networkConnectionLost) }
            return try encoder.encode(receipt)
        default: throw URLError(.badServerResponse)
        }
    }
}

final class SyncEngineTests: XCTestCase {
    private struct SavedCredential: SyncCredentialStore {
        let value: SyncPairing
        func load(account: String) throws -> SyncPairing? { value }
        func save(_ pairing: SyncPairing, account: String) throws { throw SyncClientError.alreadyPaired }
    }
    var roots: [URL] = []
    func store() throws -> LocalJournalRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fox-native-sync-\(UUID())")
        roots.append(root); return try LocalJournalRepository(directory: root)
    }
    override func tearDownWithError() throws { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func engine(_ store: LocalJournalRepository, _ server: FakeVault) throws -> JournalSyncEngine {
        try store.enableSync(vault: "vault")
        return JournalSyncEngine(repository: store, rpc: server, vault: "vault", token: "synthetic")
    }
    func testSavedCredentialRecoversUnboundRepositoryWithoutAnotherClaim() throws {
        let original = try store()
        let record = try original.record(.init(note: "retained local record"))
        XCTAssertNil(try original.syncStatus().vault)
        let credential = SavedCredential(value: .init(endpoint: URL(string: "https://example.test/v1/rpc")!,
            certificate: try SyncTransportTests.syntheticCertificate(), vault: "vault", device: UUID().uuidString, token: "synthetic"))
        let reopened = try LocalJournalRepository(directory: roots.last!)
        XCTAssertNotNil(try JournalSyncEngine.paired(repository: reopened, credentials: credential))
        XCTAssertEqual(try reopened.syncStatus().vault, "vault")
        XCTAssertEqual(try reopened.syncPending().count, 1)
        XCTAssertNotNil(try JournalSyncEngine.paired(repository: reopened, credentials: credential))
        XCTAssertEqual(try reopened.syncPending().count, 1)
        XCTAssertEqual(try reopened.get(record.id)?.note, record.note)
    }
    func testTwoNativePeersPhotoEditsDeletionAndLostReply() async throws {
        let server = FakeVault(), a = try store(), b = try store()
        let ea = try engine(a, server), eb = try engine(b, server)
        let r = try a.record(.init(note: "one", photos: [.init(data: Data([1,2,3]), mimeType: "image/png")]))
        await server.loseNextReply()
        do { _ = try await ea.run(); XCTFail("lost reply") } catch {}
        XCTAssertEqual(try a.syncStatus().pending, 1)
        _ = try await ea.run(); _ = try await eb.run()
        XCTAssertEqual(try b.get(r.id)?.note, "one")
        XCTAssertEqual(try b.photoData(r.photos[0].id), Data([1,2,3]))
        let received = try XCTUnwrap(b.get(r.id))
        var edit = CaptureEdit(from: received); edit.note = "two"
        _ = try b.revise(received.id, expectedRevision: received.revision, edit: edit)
        _ = try await eb.run(); _ = try await ea.run()
        let current = try XCTUnwrap(a.get(r.id)); XCTAssertEqual(current.note, "two")
        _ = try a.delete(r.id, expectedRevision: current.revision)
        _ = try await ea.run(); _ = try await eb.run()
        XCTAssertNil(try b.get(r.id)); XCTAssertEqual(try b.photoData(r.photos[0].id), Data([1,2,3]))
    }
    func testConflictCanSelectRemoteWithoutLosingLocalHistory() async throws {
        let server = FakeVault(), a = try store(), b = try store()
        let ea = try engine(a, server), eb = try engine(b, server)
        let first = try a.record(.init(note: "first"))
        _ = try await ea.run(); _ = try await eb.run()
        var left = CaptureEdit(from: first); left.note = "left"
        _ = try a.revise(first.id, expectedRevision: 1, edit: left)
        let copied = try XCTUnwrap(b.get(first.id)); var right = CaptureEdit(from: copied); right.note = "right"
        _ = try b.revise(copied.id, expectedRevision: copied.revision, edit: right)
        _ = try await ea.run(); _ = try await eb.run()
        XCTAssertEqual(try b.syncStatus().conflicts, 1)
        XCTAssertEqual(try b.syncConflicts().first?.remote?.note, "left")
        try b.resolveSyncConflict(first.id, keepLocal: false)
        XCTAssertEqual(try b.get(first.id)?.note, "left")
        XCTAssertTrue(try b.history(first.id).contains { $0.note == "right" })
    }
    func testPairingFileRejectsExpiredWrongSchemaAndPlaintext() throws {
        let raw: [String: Any] = ["schema": "fox.pairing.v1", "endpoint": "http://example.test/v1/rpc", "vault": "vault", "certificate": try SyncTransportTests.syntheticCertificate().base64EncodedString(), "code": "code", "expiresAt": Date().timeIntervalSince1970 * 1000 + 60_000]
        XCTAssertThrowsError(try SyncInvitation.decode(JSONSerialization.data(withJSONObject: raw)))
        var valid = raw; valid["endpoint"] = "https://example.test/v1/rpc"
        XCTAssertNoThrow(try SyncInvitation.decode(JSONSerialization.data(withJSONObject: valid)))
        var expired = valid; expired["expiresAt"] = 0
        XCTAssertThrowsError(try SyncInvitation.decode(JSONSerialization.data(withJSONObject: expired)))
        var wrong = valid; wrong["schema"] = "fox.pairing.v99"
        XCTAssertThrowsError(try SyncInvitation.decode(JSONSerialization.data(withJSONObject: wrong)))
    }
    func testOfflineChainAndKeepLocalConflictConvergeAcrossPeers() async throws {
        let server = FakeVault(), a = try store(), b = try store()
        let ea = try engine(a, server), eb = try engine(b, server)
        var r = try a.record(.init(note: "one"))
        for note in ["two", "three"] {
            var edit = CaptureEdit(from: r); edit.note = note
            r = try a.revise(r.id, expectedRevision: r.revision, edit: edit)
        }
        _ = try await ea.run(); _ = try await eb.run()
        XCTAssertEqual(try b.history(r.id).map(\.note), ["one", "two", "three"])
        var edit = CaptureEdit(from: r); edit.note = "left"
        _ = try a.revise(r.id, expectedRevision: r.revision, edit: edit)
        let copied = try XCTUnwrap(b.get(r.id)); var other = CaptureEdit(from: copied); other.note = "right"
        _ = try b.revise(r.id, expectedRevision: copied.revision, edit: other)
        _ = try await ea.run(); _ = try await eb.run()
        try b.resolveSyncConflict(r.id, keepLocal: true)
        _ = try await eb.run(); _ = try await ea.run()
        XCTAssertEqual(try a.get(r.id)?.note, "right")
        XCTAssertEqual(try b.syncStatus().conflicts, 0)
    }
    func testOversizedLocalHistoryDoesNotBlockOtherRecordsOrPull() async throws {
        let server = FakeVault(), a = try store(), b = try store()
        let ea = try engine(a, server), eb = try engine(b, server)
        _ = try a.record(.init(note: String(repeating: "x", count: 70_000)))
        _ = try a.record(.init(note: "large photo", photos: [.init(data: Data(repeating: 7, count: 26 * 1024 * 1024), mimeType: "image/png")]))
        let good = try a.record(.init(note: "normal"))
        _ = try await ea.run(); _ = try await eb.run()
        XCTAssertEqual(try b.get(good.id)?.note, "normal")
        XCTAssertEqual(try a.list().count, 3)
        XCTAssertEqual(try a.syncStatus().blocked, 2)
    }
    func testManySupportedPhotosDownloadWithoutWholeRecordMemoryLimit() async throws {
        let server = FakeVault(), a = try store(), b = try store()
        let ea = try engine(a, server), eb = try engine(b, server)
        let bytes = Data(repeating: 3, count: 6 * 1024 * 1024)
        let r = try a.record(.init(note: "72 MiB", photos: (0..<12).map { _ in .init(data: bytes, mimeType: "image/png") }))
        let next = try a.record(.init(note: "next"))
        _ = try await ea.run(); _ = try await eb.run()
        for p in r.photos { XCTAssertEqual(try b.photoData(p.id), bytes) }
        XCTAssertEqual(try b.get(next.id)?.note, "next")
    }
}
