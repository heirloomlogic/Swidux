//
//  KillswitchService.swift
//  SwiduxKillswitch
//
//  Closure-based service for fetching and caching killswitch config.
//

import Foundation
import Swidux
import os

/// Logs what the live service notices about a config it still accepts.
private let logger = Logger(subsystem: "swidux", category: "killswitch")

/// A provider-agnostic service for fetching and caching the remote
/// killswitch configuration.
public struct KillswitchService: Sendable {
    /// Fetches the latest config from the remote endpoint.
    public var fetch: @Sendable () async throws -> KillswitchConfig
    /// Loads the last persisted config from local cache, or `nil`.
    public var loadCached: @Sendable () -> KillswitchConfig?
    /// Persists a config to local cache.
    public var saveCached: @Sendable (KillswitchConfig) -> Void
    /// How long a cached config is considered fresh, in seconds.
    public let cacheLifetime: TimeInterval
    /// The longest the plugin waits on ``fetch``, in seconds.
    ///
    /// The plugin runs one network fetch at a time, so a fetch that never
    /// returns would hold every later `.fetch` and `.forceFetch` for the rest
    /// of the session, the incident-response refresh included. Past this
    /// bound the plugin abandons it, even if it ignores cancellation, and
    /// treats it as failed (`URLError.timedOut`), falling back to the cache.
    /// A value that isn't finite and positive means no bound.
    public let fetchTimeout: TimeInterval
    /// Where ``fetch`` goes, for the plugin's failure log. Set by ``live(endpoint:fetchTimeout:cacheLifetime:session:)``;
    /// `nil` for a service built from closures, whose destination the plugin can't know.
    var endpoint: URL?

    /// Creates a service with the given closures.
    ///
    /// - Parameters:
    ///   - fetch: Fetches the latest config.
    ///   - loadCached: Loads the last persisted config, or `nil`. Called
    ///     synchronously on the main actor for a `.fetch` inside the
    ///     freshness window, so keep it to a small local read.
    ///   - saveCached: Persists a config.
    ///   - cacheLifetime: How long a cached config is considered fresh, in
    ///     seconds.
    ///   - fetchTimeout: The longest the plugin waits on `fetch`, in seconds.
    public init(
        fetch: @escaping @Sendable () async throws -> KillswitchConfig,
        loadCached: @escaping @Sendable () -> KillswitchConfig?,
        saveCached: @escaping @Sendable (KillswitchConfig) -> Void,
        cacheLifetime: TimeInterval,
        fetchTimeout: TimeInterval = 30
    ) {
        self.fetch = fetch
        self.loadCached = loadCached
        self.saveCached = saveCached
        self.cacheLifetime = cacheLifetime
        self.fetchTimeout = fetchTimeout
    }

    // MARK: - Live

    /// Maximum accepted config payload. Config JSON is a few KB; anything
    /// approaching this is a misconfigured or hostile endpoint.
    private static let maxResponseBytes = 1_000_000

    /// Production factory that fetches from a URL endpoint and caches to
    /// the system Caches directory.
    ///
    /// The endpoint must be HTTPS (`http` is allowed only for `localhost` /
    /// `127.0.0.1` development servers) — the killswitch is a remote control
    /// channel and must not be tamperable in transit, regardless of the host
    /// app's ATS configuration. The transfer is aborted the moment the response
    /// body exceeds 1 MB (it is streamed, never fully buffered past the cap),
    /// and non-2xx statuses are treated as fetch failures (the plugin then
    /// falls back to its cache).
    ///
    /// `fetchTimeout` bounds the whole fetch, headers and body together — not
    /// just the gap between packets. A response trickled in a byte at a time
    /// still fails at `fetchTimeout`, so the plugin reaches its cached verdict
    /// on schedule instead of waiting on a transfer that never ends. A
    /// `fetchTimeout` that isn't finite and positive (`.infinity`, say) sets
    /// no deadline, leaving only the session's own timeouts.
    ///
    /// ## The cache is the other input path
    ///
    /// A cached config produces a verdict with exactly the authority a fetched
    /// one has, and it is reached without any successful fetch ever having
    /// happened — launch offline and the failure path loads it directly. So it
    /// is scoped and checked rather than trusted:
    ///
    /// - It lives in a **bundle-scoped subdirectory** of the caches directory.
    ///   On a non-sandboxed macOS build `.cachesDirectory` is `~/Library/Caches`,
    ///   shared by the whole user account, so a bare filename would have every
    ///   Swidux app reading every other's blocked verdict.
    /// - It records the **endpoint it came from**, and ``loadCached`` treats a
    ///   payload written for a different one as absent. Repointing the endpoint
    ///   therefore invalidates the cache rather than inheriting it.
    ///
    /// Neither of those makes the file authenticated. A process running as the
    /// user can still write it on a platform where the caches directory isn't
    /// sandboxed — see <doc:/Swidux/SecurityPosture>.
    public static func live(
        endpoint: URL,
        fetchTimeout: TimeInterval = 10,
        cacheLifetime: TimeInterval = 3600,
        session: URLSession = .shared
    ) -> KillswitchService {
        precondition(
            endpoint.scheme == "https"
                || (endpoint.scheme == "http" && ["localhost", "127.0.0.1"].contains(endpoint.host())),
            "KillswitchService endpoint must use HTTPS: \(endpoint)"
        )
        let cacheURL = Self.cacheFileURL()
        let origin = endpoint.absoluteString

        var service = KillswitchService(
            fetch: {
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = fetchTimeout
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let data = try await BoundedResponse.data(
                    for: request, session: session, limit: Self.maxResponseBytes,
                    deadline: BoundedResponse.deadline(forTimeout: fetchTimeout)
                )
                let config = try JSONDecoder().decode(KillswitchConfig.self, from: data)
                #if DEBUG
                for key in KillswitchConfig.unknownKeys(in: data) {
                    logger.warning(
                        """
                        Killswitch config key \(key, privacy: .public) is not one this build \
                        reads, so it has no effect. Check the spelling.
                        """
                    )
                }
                #endif
                return config
            },
            loadCached: {
                guard let data = try? Data(contentsOf: cacheURL),
                    let cached = try? JSONDecoder().decode(CachedConfig.self, from: data),
                    cached.endpoint == origin
                else { return nil }
                return cached.config
            },
            saveCached: { config in
                guard let data = try? JSONEncoder().encode(CachedConfig(endpoint: origin, config: config))
                else { return }
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            },
            cacheLifetime: cacheLifetime,
            fetchTimeout: fetchTimeout
        )
        service.endpoint = endpoint
        return service
    }

    /// A cached config plus the endpoint it was fetched from.
    ///
    /// The endpoint is what makes a cache refusable. Without it the file is just
    /// a config, and a config is a verdict — so anything that could put one
    /// there could block the app, including the previous build pointing at a
    /// different URL.
    private struct CachedConfig: Codable {
        let endpoint: String
        let config: KillswitchConfig
    }

    /// The subdirectory the cache lives in — the host bundle's identifier, or a
    /// fixed fallback where there isn't one (a CLI tool, a test host).
    ///
    /// Internal so a test can assert the scoping rather than restate the path.
    static var cacheScope: String {
        Bundle.main.bundleIdentifier ?? "swidux-killswitch"
    }

    /// Where the cached config lives. Internal for the same reason as
    /// ``cacheScope``.
    static func cacheFileURL() -> URL {
        let cachesDirectory =
            FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return
            cachesDirectory
            .appendingPathComponent(cacheScope, isDirectory: true)
            .appendingPathComponent("swidux-killswitch.json")
    }

    // MARK: - Mock

    /// Test factory with an in-memory cache.
    public static func mock(
        result: @escaping @Sendable () async throws -> KillswitchConfig = {
            KillswitchConfig()
        },
        cached: KillswitchConfig? = nil,
        cacheLifetime: TimeInterval = 3600
    ) -> KillswitchService {
        let cache = MockCache(initial: cached)

        return KillswitchService(
            fetch: result,
            loadCached: { cache.load() },
            saveCached: { config in cache.save(config) },
            cacheLifetime: cacheLifetime
        )
    }

    // MARK: - MockCache

    /// Thread-safe in-memory cache for testing.
    private final class MockCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: KillswitchConfig?

        init(initial: KillswitchConfig?) {
            self.stored = initial
        }

        func load() -> KillswitchConfig? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func save(_ config: KillswitchConfig) {
            lock.lock()
            defer { lock.unlock() }
            stored = config
        }
    }
}
