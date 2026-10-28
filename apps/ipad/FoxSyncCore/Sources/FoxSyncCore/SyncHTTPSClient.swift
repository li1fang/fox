import Foundation
import Security

public enum SyncTransportError: Error { case invalidConfiguration, invalidFrame, rejected(Int), invalidResponse }

// The anchor arrives over the trusted pairing channel, never from this connection.
private final class TrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    let anchor: SecCertificate
    init(host: String, anchor: SecCertificate) { self.host = host; self.anchor = anchor }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust,
              SyncHTTPSClient.validateTrust(trust, anchor: anchor, host: host) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class SyncHTTPSClient: @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let responseLimit: Int

    public convenience init(endpoint: URL, certificate: Data) throws {
        try self.init(endpoint: endpoint, certificate: certificate, configuration: .ephemeral, responseLimit: 32 * 1024 * 1024)
    }

    init(endpoint: URL, certificate: Data, configuration: URLSessionConfiguration, responseLimit: Int) throws {
        guard endpoint.scheme == "https", let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path == "/v1/rpc", let anchor = SecCertificateCreateWithData(nil, certificate as CFData) else {
            throw SyncTransportError.invalidConfiguration
        }
        self.endpoint = endpoint; self.responseLimit = responseLimit
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: TrustDelegate(host: host, anchor: anchor), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    static func validateTrust(_ trust: SecTrust, anchor: SecCertificate, host: String) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess &&
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess &&
        SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess && SecTrustEvaluateWithError(trust, nil)
    }

    public static func frame(header: Data, body: Data = Data()) throws -> Data {
        guard header.count < 65_536, !header.contains(10), body.count <= 25 * 1024 * 1024,
              (try? JSONSerialization.jsonObject(with: header)) is [String: Any] else { throw SyncTransportError.invalidFrame }
        var result = header; result.append(10); result.append(body); return result
    }

    public func send(header: Data, body: Data = Data()) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.frame(header: header, body: body)
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw SyncTransportError.invalidResponse }
        guard http.statusCode == 200 else { throw SyncTransportError.rejected(http.statusCode) }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < responseLimit else { throw SyncTransportError.invalidResponse }
            bytes.append(byte)
        }
        return bytes
    }
}
