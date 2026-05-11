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
    /// URL of the JSON config endpoint.
    public let url: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    /// Creates a service that fetches the feature-flags JSON from `url`.
    public init(
        url: URL,
        session: URLSession = .shared,
        decoder: JSONDecoder = .init()
    ) {
        self.url = url
        self.session = session
        self.decoder = decoder
    }

    /// Fetches and decodes the wire-format config. Throws on transport
    /// failures, non-2xx responses, and decode errors.
    public func fetch() async throws -> FeatureFlagsConfig {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        return try decoder.decode(FeatureFlagsConfig.self, from: data)
    }
}
