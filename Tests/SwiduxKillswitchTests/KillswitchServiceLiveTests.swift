//
//  KillswitchServiceLiveTests.swift
//  SwiduxKillswitchTests
//

import Foundation
import Testing

@testable import SwiduxKillswitch

@Suite("KillswitchService.live", .serialized)
struct KillswitchServiceLiveTests {
    // MARK: - Fetch

    @Test("decodes a valid JSON response")
    func decodesValidResponse() async throws {
        let json = """
            { "minimumSupportedVersion": "2.0.0", "blockedVersions": ["1.9.9"] }
            """
        let url = URL(static: "https://example.test/killswitch.json")
        let session = StubURLSession.with(data: Data(json.utf8), response: .ok(url: url))
        let service = KillswitchService.live(endpoint: url, session: session)

        let config = try await service.fetch()

        #expect(config.minimumSupportedVersion == "2.0.0")
        #expect(config.blockedVersions == ["1.9.9"])
    }

    @Test("throws on non-2xx response without decoding the body")
    func throwsOnHTTPError() async {
        let url = URL(static: "https://example.test/killswitch.json")
        // A perfectly decodable body: if the status guard were skipped this
        // would decode cleanly, so a throw proves the body is never read.
        let body = Data(#"{ "minimumSupportedVersion": "2.0.0" }"#.utf8)
        let session = StubURLSession.with(data: body, response: .status(500, url: url))
        let service = KillswitchService.live(endpoint: url, session: session)

        let error = await #expect(throws: URLError.self) {
            _ = try await service.fetch()
        }
        #expect(error?.code == .badServerResponse)
    }

    @Test("throws when the body exceeds the 1 MB cap")
    func throwsOnOversizedBody() async {
        let url = URL(static: "https://example.test/killswitch.json")
        let oversized = Data(repeating: 0x7B, count: 1_000_001)
        let session = StubURLSession.with(data: oversized, response: .ok(url: url))
        let service = KillswitchService.live(endpoint: url, session: session)

        let error = await #expect(throws: URLError.self) {
            _ = try await service.fetch()
        }
        #expect(error?.code == .dataLengthExceedsMaximum)
    }

    @Test("rejects early on an oversized declared Content-Length")
    func rejectsOversizedContentLength() async {
        let url = URL(static: "https://example.test/killswitch.json")
        // Tiny body, but the response claims a payload far above the cap.
        let session = StubURLSession.with(
            data: Data("{}".utf8),
            response: .status(200, url: url, headers: ["Content-Length": "5000000"])
        )
        let service = KillswitchService.live(endpoint: url, session: session)

        let error = await #expect(throws: URLError.self) {
            _ = try await service.fetch()
        }
        #expect(error?.code == .dataLengthExceedsMaximum)
    }

    // MARK: - Cache

    @Test("saveCached / loadCached round-trips a config")
    func cacheRoundTrip() async throws {
        let url = URL(static: "https://example.test/killswitch.json")
        let session = StubURLSession.with(data: Data(), response: .ok(url: url))
        let service = KillswitchService.live(endpoint: url, session: session)
        defer { Self.removeCacheFile() }

        let config = KillswitchConfig(
            minimumSupportedVersion: "3.1.4",
            blockedVersions: ["3.0.0"],
            blockedTitle: "Update required"
        )
        service.saveCached(config)

        #expect(service.loadCached() == config)
    }

    @Test("a cache written for another endpoint is not read")
    func cacheIsBoundToItsEndpoint() async throws {
        defer { Self.removeCacheFile() }
        let written = URL(static: "https://a.test/killswitch.json")
        let read = URL(static: "https://b.test/killswitch.json")
        let session = StubURLSession.with(data: Data(), response: .ok(url: written))

        KillswitchService.live(endpoint: written, session: session)
            .saveCached(KillswitchConfig(minimumSupportedVersion: "9.9.9"))

        // Same file, different endpoint. The cache is the killswitch's second
        // input path and carries the same authority as the endpoint, so a
        // payload this build didn't ask for has to read as absent — not as a
        // verdict. Fail-open means the tick then goes to the network.
        #expect(KillswitchService.live(endpoint: read, session: session).loadCached() == nil)
        #expect(KillswitchService.live(endpoint: written, session: session).loadCached() != nil)
    }

    @Test("a cache from an unreadable file reads as absent rather than throwing")
    func corruptCacheReadsAsAbsent() async throws {
        defer { Self.removeCacheFile() }
        let url = URL(static: "https://example.test/killswitch.json")
        let session = StubURLSession.with(data: Data(), response: .ok(url: url))
        let service = KillswitchService.live(endpoint: url, session: session)
        let cacheURL = KillswitchService.cacheFileURL()

        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: cacheURL, options: .atomic)

        #expect(service.loadCached() == nil)
    }

    @Test("the cache is scoped to this bundle, not shared across every Swidux app")
    func cacheIsScopedToTheBundle() {
        let cachesDirectory =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let cacheURL = KillswitchService.cacheFileURL()

        // On a non-sandboxed macOS build `.cachesDirectory` is `~/Library/Caches`,
        // shared by every process in the user account — so an unscoped filename
        // means one Swidux app reads another's blocked verdict.
        #expect(cacheURL.deletingLastPathComponent().standardizedFileURL != cachesDirectory.standardizedFileURL)
        #expect(cacheURL.deletingLastPathComponent().lastPathComponent == KillswitchService.cacheScope)
    }

    /// Removes the whole scoped cache directory so a round-trip test leaves no
    /// residue for other tests or runs.
    private static func removeCacheFile() {
        try? FileManager.default.removeItem(
            at: KillswitchService.cacheFileURL().deletingLastPathComponent())
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
        status(200, url: url)
    }
    fileprivate static func status(
        _ code: Int, url: URL, headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        else {
            preconditionFailure("HTTPURLResponse(\(code)) construction failed for \(url)")
        }
        return response
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
