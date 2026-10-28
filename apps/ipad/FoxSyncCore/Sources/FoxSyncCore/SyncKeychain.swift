import Foundation
import Security

public struct SyncKeychain: SyncCredentialStore {
    public init() {}
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "fox.personal-sync.v1", kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    public func load(account: String) throws -> SyncPairing? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SyncClientError.missingCredentials }
        return try JSONDecoder().decode(SyncPairing.self, from: data)
    }
    public func save(_ pairing: SyncPairing, account: String) throws {
        var q = query(account)
        q[kSecValueData as String] = try JSONEncoder().encode(pairing)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Never replace an existing device identity implicitly.
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw SyncClientError.alreadyPaired }
    }
}
