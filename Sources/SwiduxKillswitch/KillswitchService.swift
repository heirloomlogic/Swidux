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

        return KillswitchService(
            fetch: {
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = fetchTimeout
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let data = try await boundedData(
                    for: request, session: session, limit: Self.maxResponseBytes
                )
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
