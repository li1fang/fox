import CryptoKit
import Foundation

// Test-only dependency: private locations are supplied explicitly; missing input is never a skip.
public enum PrivateFixtures {
    private struct Asset: Decodable { let path: String; let sha256: String; let bytes: Int }
    private struct Manifest: Decodable { let schema: String; let assets: [String: Asset] }
    private struct Pinned: Decodable { let sha256: String }
    private struct Contract: Decodable { let assets: [String: Pinned] }

    public static func url(_ id: String) throws -> URL {
        func invalid(_ reason: String) -> NSError {
            NSError(domain: "FoxPrivateFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(id): \(reason)"])
        }
        guard let location = ProcessInfo.processInfo.environment["FOX_PRIVATE_INPUT_MANIFEST"] else {
            throw invalid("FOX_PRIVATE_INPUT_MANIFEST required; missing private evidence is not a pass")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: location)))
        let resource = Bundle.module.url(forResource: "private-inputs.contract", withExtension: "json")!
        let contract = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: resource))
        guard manifest.schema == "fox.private_inputs.v1", let asset = manifest.assets[id],
              asset.path.hasPrefix("/"), asset.sha256 == contract.assets[id]?.sha256 else {
            throw invalid("invalid location or pinned digest")
        }
        let url = URL(fileURLWithPath: asset.path), bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard bytes.count == asset.bytes, digest == asset.sha256 else { throw invalid("private bytes changed") }
        return url
    }
}
