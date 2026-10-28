import Foundation
import FoxSyncCore

// Development-only executable. Request/response files must be private synthetic fixtures.
@main struct Probe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, let endpoint = URL(string: args[1]) else { throw SyncTransportError.invalidConfiguration }
        let client = try SyncHTTPSClient(endpoint: endpoint, certificate: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let result = try await client.send(header: Data(contentsOf: URL(fileURLWithPath: args[3])))
        let destination = URL(fileURLWithPath: args[4])
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SyncTransportError.invalidConfiguration }
        try result.write(to: destination, options: .withoutOverwriting)
        print("sync_transport_probe_passed")
    }
}
