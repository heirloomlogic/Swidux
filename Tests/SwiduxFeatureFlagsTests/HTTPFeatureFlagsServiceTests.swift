//
//  HTTPFeatureFlagsServiceTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("HTTPFeatureFlagsService", .serialized)
struct HTTPFeatureFlagsServiceTests {
    @Test("decodes a valid JSON response")
    func decodesValidResponse() async throws {
        let json = """
            { "version": 1, "flags": { "f": { "type": "boolean", "rollout": 50 } } }
            """
        let url = URL(string: "https://example.test/flags.json")!
        let session = StubURLSession.with(data: Data(json.utf8), response: .ok(url: url))

        let service = HTTPFeatureFlagsService(url: url, session: session)
        let config = try await service.fetch()

        #expect(config.version == 1)
        #expect(config.flags.count == 1)
    }

    @Test("throws on non-2xx response")
    func throwsOnHTTPError() async {
        let url = URL(string: "https://example.test/flags.json")!
        let session = StubURLSession.with(data: Data(), response: .status(500, url: url))
        let service = HTTPFeatureFlagsService(url: url, session: session)

        await #expect(throws: (any Error).self) {
            _ = try await service.fetch()
        }
    }

    @Test("throws on malformed JSON")
    func throwsOnMalformedJSON() async {
        let url = URL(string: "https://example.test/flags.json")!
        let session = StubURLSession.with(data: Data("not json".utf8), response: .ok(url: url))
        let service = HTTPFeatureFlagsService(url: url, session: session)

        await #expect(throws: (any Error).self) {
            _ = try await service.fetch()
        }
    }
}

// MARK: - URLSession stub helpers

private enum StubURLSession {
    static func with(data: Data, response: HTTPURLResponse) -> URLSession {
        URLProtocolStub.installer = { (data, response) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }
}

extension HTTPURLResponse {
    fileprivate static func ok(url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
    fileprivate static func status(_ code: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var installer: (() -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (data, response) = URLProtocolStub.installer?() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
