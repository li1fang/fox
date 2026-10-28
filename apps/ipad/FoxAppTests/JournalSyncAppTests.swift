import Foundation
import Security
import XCTest
import FoxSyncCore
import FoxJournalCore
import FoxTrainingCore
import SwiftUI
@testable import Fox

private struct SyntheticCredential: SyncCredentialStore {
    func load(account: String) throws -> SyncPairing? {
        .init(endpoint: URL(string: "https://example.test/v1/rpc")!, certificate: Data(), vault: "test", device: "test", token: "synthetic")
    }
    func save(_ pairing: SyncPairing, account: String) throws { throw SyncClientError.alreadyPaired }
}
private actor PausedSyncRPC: SyncRPC {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func send(header: Data, body: Data) async throws -> Data {
        calls += 1; started?.resume(); started = nil
        await withCheckedContinuation { continuation = $0 }
        throw URLError(.notConnectedToInternet)
    }
}

final class JournalSyncAppTests: XCTestCase {
    @MainActor private func fixture() throws -> (JournalStore, PausedSyncRPC, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let rpc = PausedSyncRPC()
        return (JournalStore(directory: directory.appendingPathComponent("Journal"), exportDirectory: directory.appendingPathComponent("Exports"),
                             credentials: SyntheticCredential(), syncRPC: rpc), rpc, directory)
    }
    @MainActor func testConcurrentSyncAndConflictTapCannotReleaseRunningOwner() async throws {
        let (store, rpc, _) = try fixture()
        let first = Task { await store.synchronize(ifPairedOnly: true) }
        let second = Task { await store.synchronize(ifPairedOnly: true) }
        await rpc.waitUntilStarted()
        // Let both entry tasks pass their initial state refresh while transport is held.
        for _ in 0..<20 { await Task.yield() }
        await store.resolveSync(UUID(), keepLocal: false)
        XCTAssertTrue(store.syncing)
        let calls = await rpc.calls; XCTAssertEqual(calls, 1)
        await rpc.release(); await first.value; await second.value
        XCTAssertFalse(store.syncing)
        XCTAssertNotNil(store.syncError)
        XCTAssertEqual(store.syncState?.vault, "test")
    }
    @MainActor func testHomeLoadsLocalTrainingWhileSyncWaits() async throws {
        let (store, rpc, directory) = try fixture()
        let url = directory.appendingPathComponent("training.json")
        let archive = TrainingArchive()
        try LocalTrainingRepository.encoder().encode(archive).write(to: url)
        let training = HomeTrainingStore(url: url)
        let host = UIHostingController(rootView: FoxHomeView(journal: store, trainingArchive: training))
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await rpc.waitUntilStarted()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(training.loaded)
        XCTAssertNotNil(training.snapshot.plan)
        XCTAssertTrue(store.syncing)
        await rpc.release()
    }
    func testPairingCredentialPersistsAndCannotBeSilentlyReplaced() throws {
        let account = "synthetic-test-" + UUID().uuidString
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "fox.personal-sync.v1", kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false]
        defer { SecItemDelete(query as CFDictionary) }
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecItemNotFound, "Keychain preflight OSStatus=\(status)")
        let store = SyncKeychain()
        XCTAssertNil(try store.load(account: account))
        let original = SyncPairing(endpoint: URL(string: "https://example.test/v1/rpc")!, certificate: Data([1]), vault: "test", device: "test", token: "synthetic")
        try store.save(original, account: account)
        XCTAssertEqual(try SyncKeychain().load(account: account)?.token, original.token)
        let changed = SyncPairing(endpoint: original.endpoint, certificate: original.certificate, vault: "different", device: "other", token: "changed")
        XCTAssertThrowsError(try store.save(changed, account: account))
        XCTAssertEqual(try store.load(account: account)?.vault, "test")
    }
}
