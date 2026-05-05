//
//  KillswitchService.swift
//  SwiduxKillswitch
//
//  Closure-based service for fetching and caching killswitch config.
//

import Foundation

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

    /// Creates a service with the given closures.
    public init(
        fetch: @escaping @Sendable () async throws -> KillswitchConfig,
        loadCached: @escaping @Sendable () -> KillswitchConfig?,
        saveCached: @escaping @Sendable (KillswitchConfig) -> Void,
        cacheLifetime: TimeInterval
    ) {
        self.fetch = fetch
        self.loadCached = loadCached
        self.saveCached = saveCached
        self.cacheLifetime = cacheLifetime
    }

    // MARK: - Live

    /// Production factory that fetches from a URL endpoint and caches to
    /// the system Caches directory.
    public static func live(
        endpoint: URL,
        fetchTimeout: TimeInterval = 10,
        cacheLifetime: TimeInterval = 3600,
        session: URLSession = .shared
    ) -> KillswitchService {
        let cacheURL = Self.cacheFileURL()

        return KillswitchService(
            fetch: {
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = fetchTimeout
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, _) = try await session.data(for: request)
                return try JSONDecoder().decode(KillswitchConfig.self, from: data)
            },
            loadCached: {
                guard let data = try? Data(contentsOf: cacheURL),
                    let config = try? JSONDecoder().decode(KillswitchConfig.self, from: data)
                else { return nil }
                return config
            },
            saveCached: { config in
                guard let data = try? JSONEncoder().encode(config) else { return }
                try? data.write(to: cacheURL, options: .atomic)
            },
            cacheLifetime: cacheLifetime
        )
    }

    private static func cacheFileURL() -> URL {
        let cachesDirectory =
            FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return cachesDirectory.appendingPathComponent("swidux-killswitch.json")
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
