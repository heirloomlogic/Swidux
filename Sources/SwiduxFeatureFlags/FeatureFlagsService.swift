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

    /// Creates a service that fetches the feature-flags JSON from `url`.
    ///
    /// The URL must be HTTPS (`http` is allowed only for `localhost` /
    /// `127.0.0.1` development servers) — flags gate features and rollouts,
    /// so the channel must not be tamperable in transit, regardless of the
    /// host app's ATS configuration.
    public init(
        url: URL,
        session: URLSession = .shared,
        decoder: JSONDecoder = .init()
    ) {
        precondition(
            url.scheme == "https"
                || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host())),
            "HTTPFeatureFlagsService URL must use HTTPS: \(url)"
        )
        self.url = url
        self.session = session
        self.decoder = decoder
    }

    /// Fetches and decodes the wire-format config. Throws on transport
    /// failures, non-2xx responses, oversized payloads (> 1 MB), and decode
    /// errors. On failure the plugin keeps its cached config.
    public func fetch() async throws -> FeatureFlagsConfig {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard data.count <= Self.maxResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }

        return try decoder.decode(FeatureFlagsConfig.self, from: data)
    }
}
