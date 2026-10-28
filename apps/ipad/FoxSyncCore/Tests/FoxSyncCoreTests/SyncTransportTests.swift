import Foundation
import Security
import XCTest
@testable import FoxSyncCore

final class SyncTransportTests: XCTestCase {
    func testRejectsPlaintextAndCredentialURLs() throws {
        let certificate = try syntheticCertificate()
        for text in ["http://example.test/v1/rpc", "https://user:secret@example.test/v1/rpc", "https://example.test/v1/rpc?token=secret"] {
            XCTAssertThrowsError(try SyncHTTPSClient(endpoint: URL(string: text)!, certificate: certificate))
        }
    }
    func testRejectsMalformedTrustAnchor() throws {
        XCTAssertThrowsError(try SyncHTTPSClient(endpoint: URL(string: "https://example.test/v1/rpc")!, certificate: Data("not a certificate".utf8)))
    }
    func testWireHeaderIsBoundedAndTerminated() throws {
        let bytes = try SyncHTTPSClient.frame(header: Data("{\"action\":\"pull\"}".utf8), body: Data([1, 2]))
        XCTAssertTrue(bytes.starts(with: Data("{\"action\":\"pull\"}\n".utf8)))
        XCTAssertEqual(bytes.suffix(2), Data([1, 2]))
        XCTAssertThrowsError(try SyncHTTPSClient.frame(header: Data(repeating: 65, count: 65_536), body: Data()))
        XCTAssertThrowsError(try SyncHTTPSClient.frame(header: Data("{}\n{}".utf8), body: Data()))
    }

    func testStreamingLimitCancelsWithoutContentLength() async throws {
        try await boundedResponse(status: 200)
    }
    func testErrorResponseDoesNotDownloadUnboundedBody() async throws {
        try await boundedResponse(status: 500)
    }
    func testTrustChecksAnchorHostnameAndExpiry() throws {
        let certificate = SecCertificateCreateWithData(nil, try syntheticCertificate() as CFData)!
        let other = SecCertificateCreateWithData(nil, try syntheticCertificate() as CFData)!
        func trust() -> SecTrust {
            var value: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates([certificate] as CFArray, SecPolicyCreateSSL(true, "example.test" as CFString), &value), errSecSuccess)
            return value!
        }
        XCTAssertTrue(SyncHTTPSClient.validateTrust(trust(), anchor: certificate, host: "example.test"))
        XCTAssertFalse(SyncHTTPSClient.validateTrust(trust(), anchor: other, host: "example.test"))
        XCTAssertFalse(SyncHTTPSClient.validateTrust(trust(), anchor: certificate, host: "wrong.example"))
        let expired = trust()
        XCTAssertEqual(SecTrustSetVerifyDate(expired, Date().addingTimeInterval(3 * 86_400) as CFDate), errSecSuccess)
        XCTAssertFalse(SyncHTTPSClient.validateTrust(expired, anchor: certificate, host: "example.test"))
    }
    private func boundedResponse(status: Int) async throws {
        ChunkProtocol.status = status; ChunkProtocol.sent = 0
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChunkProtocol.self]
        let client = try SyncHTTPSClient(endpoint: URL(string: "https://example.test/v1/rpc")!,
            certificate: syntheticCertificate(), configuration: config, responseLimit: 1_024)
        do { _ = try await client.send(header: Data("{}".utf8)); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error is SyncTransportError) }
        XCTAssertLessThan(ChunkProtocol.sent, 100)
    }
    private func syntheticCertificate() throws -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("openssl.cnf")
        try Data("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=example.test\n[ext]\nsubjectAltName=DNS:example.test\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:TRUE\n".utf8).write(to: config)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", config.path,
            "-keyout", root.appendingPathComponent("key.pem").path, "-outform", "DER", "-out", root.appendingPathComponent("cert.der").path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: root.appendingPathComponent("cert.der"))
    }
}

private final class ChunkProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    private static let counterLock = NSLock()
    private static var count = 0
    static var sent: Int {
        get { counterLock.lock(); defer { counterLock.unlock() }; return count }
        set { counterLock.lock(); defer { counterLock.unlock() }; count = newValue }
    }
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async {
            for _ in 0..<100 {
                self.lock.lock(); let stop = self.stopped; self.lock.unlock()
                if stop { return }
                Self.sent += 1
                self.client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 256))
                Thread.sleep(forTimeInterval: 0.005)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
