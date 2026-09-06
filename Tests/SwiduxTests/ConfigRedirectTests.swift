import Foundation
import Testing

@testable import Swidux

@Suite("Remote config redirects")
struct ConfigRedirectTests {
    @Test(
        "Redirects cannot downgrade HTTPS or escape local HTTP",
        arguments: [
            ("https://example.test/config", "https://cdn.example.test/config", true),
            ("https://example.test/config", "http://example.test/config", false),
            ("https://example.test/config", "http://localhost/config", false),
            ("https://example.test/config", "file:///tmp/config", false),
            ("http://localhost/config", "http://127.0.0.1/config", true),
            ("http://localhost/config", "http://example.test/config", false),
        ])
    func redirectPolicy(source: String, destination: String, allowed: Bool) async throws {
        let sourceURL = try #require(URL(string: source))
        let target = URLRequest(url: try #require(URL(string: destination)))
        let response = try #require(
            HTTPURLResponse(
                url: sourceURL, statusCode: 302, httpVersion: nil, headerFields: nil))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: sourceURL)
        let decision: URLRequest? = await withCheckedContinuation { continuation in
            SecureConfigRedirects().urlSession(
                session, task: task, willPerformHTTPRedirection: response, newRequest: target
            ) { continuation.resume(returning: $0) }
        }
        #expect((decision != nil) == allowed)
    }
}
