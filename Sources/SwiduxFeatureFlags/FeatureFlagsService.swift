//
//  FeatureFlagsService.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Provider-agnostic feature-flags backend.
///
/// Implementations need only fetch the wire-format config. Caching,
/// hydration, and evaluation are owned by the plugin so they are identical
/// regardless of backend. Built-in: ``HTTPFeatureFlagsService``. Third-party
/// adapters (LaunchDarkly, GrowthBook, Statsig) conform without changing
/// the plugin.
public protocol FeatureFlagsService: Sendable {
    func fetch() async throws -> FeatureFlagsConfig
}

/// Default service: fetches the JSON wire format from a URL.
///
/// Apps host their flags JSON wherever convenient — static file on a CDN,
/// Cloudflare Worker, their own backend. Zero infrastructure required.
public struct HTTPFeatureFlagsService: FeatureFlagsService {
    /// Maximum accepted config payload. Flags JSON is a few KB; anything
    /// approaching this is a misconfigured or hostile endpoint.
    private static let maxResponseBytes = 1_000_000

    /// URL of the JSON config endpoint.
    public let url: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let fetchTimeout: TimeInterval

    /// Creates a service that fetches the feature-flags JSON from `url`.
    ///
    /// The URL must be HTTPS (`http` is allowed only for `localhost` /
    /// `127.0.0.1` development servers) — flags gate features and rollouts,
    /// so the channel must not be tamperable in transit, regardless of the
    /// host app's ATS configuration.
    ///
    /// - Parameters:
    ///   - url: The JSON config endpoint; must be HTTPS.
    ///   - session: The URL session to fetch with.
    ///   - decoder: The decoder for the wire-format config.
    ///   - fetchTimeout: Per-request timeout in seconds. Flags are a small
    ///     control channel; a hung request shouldn't wait the URLSession
    ///     default 60 s to fall back to the cached config.
    public init(
        url: URL,
        session: URLSession = .shared,
        decoder: JSONDecoder = .init(),
        fetchTimeout: TimeInterval = 10
    ) {
        precondition(
            url.scheme == "https"
                || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host())),
            "HTTPFeatureFlagsService URL must use HTTPS: \(url)"
        )
        self.url = url
        self.session = session
        self.decoder = decoder
        self.fetchTimeout = fetchTimeout
    }

    /// Fetches and decodes the wire-format config. Throws on transport
    /// failures, non-2xx responses, and decode errors; the transfer is aborted
    /// once the response body exceeds the 1 MB cap (it is streamed, never fully
    /// buffered past the cap). On failure the plugin keeps its cached config.
    public func fetch() async throws -> FeatureFlagsConfig {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = fetchTimeout

        let data = try await Self.boundedData(
            for: request, session: session, limit: Self.maxResponseBytes
        )

        return try decoder.decode(FeatureFlagsConfig.self, from: data)
    }

    /// Streams the response body while enforcing `limit`, so the process never
    /// buffers a hostile or misconfigured payload whole.
    ///
    /// The HTTP status is checked before the body is read (non-2xx throws
    /// ``URLError/badServerResponse``); a declared `Content-Length` above the
    /// cap is rejected immediately; otherwise bytes are accumulated chunk by
    /// chunk and the transfer is aborted with
    /// ``URLError/dataLengthExceedsMaximum`` once the accumulated count exceeds
    /// `limit` — never holding more than the cap plus one chunk.
    private static func boundedData(
        for request: URLRequest,
        session: URLSession,
        limit: Int
    ) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if response.expectedContentLength > Int64(limit) {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), limit))
        }
        let chunkSize = 65_536
        var chunk = [UInt8]()
        chunk.reserveCapacity(chunkSize)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == chunkSize {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                if data.count > limit {
                    throw URLError(.dataLengthExceedsMaximum)
                }
            }
        }
        data.append(contentsOf: chunk)
        if data.count > limit {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return data
    }
}
