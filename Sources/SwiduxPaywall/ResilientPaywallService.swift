//
//  ResilientPaywallService.swift
//  SwiduxPaywall
//

import Foundation
import Swidux

/// `Codable` mirror of ``EntitlementSnapshot`` (which is not `Codable`) so the
/// last-known-good entitlement can be persisted through a ``KeyValueStore``.
public struct CachedEntitlement: Codable, Sendable, Equatable {
    /// `true` when the user had an active pro subscription at the time of caching.
    public var isPro: Bool
    /// `true` when the user owned a permanent/lifetime license at the time of caching.
    public var hasPermanentLicense: Bool
    /// When this snapshot was captured from a live read. Drives the staleness
    /// policy in ``ResilientPaywallService``.
    public var cachedAt: Date

    /// Creates a cached entitlement with the given status.
    ///
    /// - Parameters:
    ///   - isPro: Whether an active pro subscription was held.
    ///   - hasPermanentLicense: Whether a permanent/lifetime license was owned.
    ///   - cachedAt: When the snapshot was captured from a live read.
    public init(isPro: Bool, hasPermanentLicense: Bool, cachedAt: Date = Date()) {
        self.isPro = isPro
        self.hasPermanentLicense = hasPermanentLicense
        self.cachedAt = cachedAt
    }

    /// Captures the entitlement status of `snapshot`.
    ///
    /// - Parameters:
    ///   - snapshot: The live entitlement snapshot to cache.
    ///   - cachedAt: When the snapshot was captured from a live read.
    public init(_ snapshot: EntitlementSnapshot, cachedAt: Date = Date()) {
        self.isPro = snapshot.isPro
        self.hasPermanentLicense = snapshot.hasPermanentLicense
        self.cachedAt = cachedAt
    }

    /// The equivalent ``EntitlementSnapshot``.
    public var snapshot: EntitlementSnapshot {
        EntitlementSnapshot(isPro: isPro, hasPermanentLicense: hasPermanentLicense)
    }

    /// Equality compares entitlement content only — `cachedAt` is transient
    /// bookkeeping, mirroring how `EntityStore` excludes its changelog.
    public static func == (lhs: CachedEntitlement, rhs: CachedEntitlement) -> Bool {
        lhs.isPro == rhs.isPro && lhs.hasPermanentLicense == rhs.hasPermanentLicense
    }
}

extension KVKey where Value == CachedEntitlement {
    /// The last entitlement snapshot a successful read delivered. Versioned so a
    /// future shape change declares a new key rather than silently failing to
    /// decode (``KeyValueStore`` has no migration).
    public static let lastKnownEntitlement = KVKey<CachedEntitlement>(
        "swidux.paywall.lastKnownEntitlement.v2"
    )
}

/// The pre-`cachedAt` payload shape persisted under the v1 key. Read once for
/// migration, then removed.
private struct LegacyCachedEntitlementV1: Codable, Sendable {
    var isPro: Bool
    var hasPermanentLicense: Bool
}

private let legacyV1Key = KVKey<LegacyCachedEntitlementV1>(
    "swidux.paywall.lastKnownEntitlement.v1"
)

/// Wraps a ``PaywallService`` so a transient failure to read entitlements never
/// presents a previously-seen paid user as free.
///
/// ``PaywallPlugin`` populates ``PaywallState`` — and therefore the feature gate,
/// account display, and whether the paywall sheet is shown — entirely from the
/// snapshots its wrapped service emits. A slow, silent, or throwing entitlement
/// read at cold launch leaves that state at its `free` default. This decorator
/// keeps a persisted last-known-good so the gate never collapses to free on a
/// transient failure, while the server remains the authoritative gate: a later
/// live snapshot always overwrites the cache, so a genuine lapse is honoured.
///
/// The cache is bounded by `maxCacheAge` (72 hours by default): a stale cache
/// stops vouching for `isPro` — subscriptions lapse, and an install that stays
/// offline past the bound must not keep pro forever — but keeps
/// `hasPermanentLicense`, because lifetime purchases don't expire.
///
/// Provider-agnostic by construction — it speaks only ``PaywallService``, so it
/// wraps any base (simulated, RevenueCat, StoreKit, …). Feed the wrapped instance
/// to *both* ``PaywallPlugin`` and any app-side reader that builds a
/// monetization/context payload from entitlements.
///
/// Back the cache with `KeychainKeyValueStore` rather than `UserDefaults`: the
/// cache vouches for a paid entitlement offline, and `UserDefaults` is a plist
/// a user can edit or restore from a doctored backup, whereas the Keychain is
/// encrypted and not plist-editable. (On unsigned macOS dev builds the Keychain
/// can return `errSecMissingEntitlement` / −34018 — see *Sandboxing &
/// entitlements (macOS)* on ``KeychainKeyValueStore``.)
///
/// ```swift
/// let resilient = ResilientPaywallService(
///     base: paywallService,
///     store: KeychainKeyValueStore(service: "com.example.myapp"),
///     // Apps upgrading from a UserDefaults-backed cache migrate it once:
///     migratingFrom: UserDefaultsKeyValueStore()
/// )
/// // PaywallPlugin(..., service: resilient)   // gate + account display
/// // await resilient.currentSnapshot()        // server payload, off-main
/// ```
///
/// ## Threat model
///
/// Backed by ``KeychainKeyValueStore``, the cache defends against casual plist
/// editing and a doctored-backup restore: the persisted last-known-good is
/// encrypted and not a user-editable file. It does **not** defend against a
/// jailbroken device — nothing client-side does; entitlements can always be
/// forged on a device the attacker fully controls. The live provider stays
/// authoritative whenever the app is online: any live snapshot overwrites the
/// cache, so a genuine lapse or downgrade is honoured on the next successful
/// read. `hasPermanentLicense` deliberately never expires — a lifetime purchase
/// must keep working offline indefinitely. One residual is accepted: a
/// `UserDefaults`-backed cache edited *before* the app adopts the Keychain is
/// migrated forward at face value exactly once.
public struct ResilientPaywallService: PaywallService {
    private let base: any PaywallService
    private let store: any KeyValueStore
    /// Optional store to migrate a last-known-good *out of* on first read — set
    /// when an app moves the cache to a more secure backing (e.g. `UserDefaults`
    /// → Keychain). Consulted only on a primary miss; see ``readCache()``.
    private let legacyStore: (any KeyValueStore)?
    /// Total attempts at a live `customerInfo()` read before falling back to cache.
    private let maxAttempts: Int
    /// When `true`, ``customerInfoStream()`` yields the persisted last-known-good
    /// before live data so a flaky launch never gates a paid user as free. Causes a
    /// brief flash of the prior entitlement on a genuine downgrade; on by default.
    private let seedsFromCache: Bool
    /// Oldest cache the staleness policy will still fully honour, in seconds.
    private let maxCacheAgeInterval: TimeInterval
    /// First-retry delay; doubles per attempt with ±20 % jitter.
    private let retryBaseDelay: Duration
    /// Clock read used for `cachedAt` stamping and staleness checks.
    private let now: @Sendable () -> Date

    /// Creates a resilient decorator around `base`, persisting last-known-good
    /// through `store`.
    ///
    /// - Parameters:
    ///   - base: The live service to decorate.
    ///   - store: Where the last-known-good entitlement persists.
    ///   - legacyStore: A prior backing to migrate the cache out of, once, on a
    ///     primary miss. Pass the app's old store (e.g. `UserDefaultsKeyValueStore()`)
    ///     when moving the cache to a more secure one; the value is deleted from
    ///     `legacyStore` and written forward into `store`. `nil` (default) skips
    ///     migration entirely.
    ///   - maxAttempts: Total live-read attempts before the cache fallback.
    ///   - seedsFromCache: Whether the stream yields the cache before live data.
    ///   - maxCacheAge: Cache age beyond which `isPro` is no longer honoured
    ///     (a permanent license still is — lifetime purchases don't expire).
    ///   - retryBaseDelay: Delay before the first retry; doubles per attempt
    ///     with ±20 % jitter.
    ///   - now: Clock read for cache stamping and staleness; injectable for tests.
    public init(
        base: any PaywallService,
        store: any KeyValueStore,
        migratingFrom legacyStore: (any KeyValueStore)? = nil,
        maxAttempts: Int = 2,
        seedsFromCache: Bool = true,
        maxCacheAge: Duration = .seconds(72 * 3600),
        retryBaseDelay: Duration = .milliseconds(300),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.base = base
        self.store = store
        self.legacyStore = legacyStore
        self.maxAttempts = maxAttempts
        self.seedsFromCache = seedsFromCache
        self.maxCacheAgeInterval = Self.interval(of: maxCacheAge)
        self.retryBaseDelay = retryBaseDelay
        self.now = now
    }

    /// Fetches the current entitlement status, retrying up to `maxAttempts`
    /// with exponential backoff. On success persists and returns; if every
    /// attempt fails, returns the cached last-known-good when present and
    /// usable, otherwise rethrows (so the plugin's honest `.refreshFailed`
    /// path is preserved for a genuinely-unknown user). Cancellation stops
    /// retrying immediately and falls through to the cache.
    public func customerInfo() async throws -> EntitlementSnapshot {
        var lastError: (any Error)?
        attempts: for attempt in 1...max(1, maxAttempts) {
            if Task.isCancelled { break }
            if attempt > 1 {
                do {
                    try await Task.sleep(for: backoffDelay(beforeAttempt: attempt))
                } catch {
                    break  // Cancelled during backoff — fall through to cache.
                }
            }
            do {
                let snapshot = try await base.customerInfo()
                persist(snapshot)
                return snapshot
            } catch is CancellationError {
                break attempts
            } catch {
                lastError = error
            }
        }
        // Every attempt failed — fall back to the last-known-good so a
        // previously-seen paid user is never dropped to free. With nothing
        // usable cached the user is genuinely unknown: surface the failure.
        if let cached = readCache(), let usable = usableSnapshot(from: cached) {
            return usable
        }
        throw lastError ?? CancellationError()
    }

    /// Long-lived stream of entitlement updates. Yields the persisted
    /// last-known-good first (when ``seedsFromCache`` is on and the cache is
    /// still usable), then forwards and persists every snapshot the base
    /// stream emits.
    public func customerInfoStream() -> AsyncStream<EntitlementSnapshot> {
        let base = self.base
        let seedsFromCache = self.seedsFromCache
        let service = self
        return AsyncStream { continuation in
            // Seed with the last-known-good so a flaky launch never leaves a paid
            // user gated as free before the live snapshot arrives.
            if seedsFromCache, let cached = service.readCache(),
                let usable = service.usableSnapshot(from: cached)
            {
                continuation.yield(usable)
            }
            let task = Task {
                for await snapshot in base.customerInfoStream() {
                    service.persist(snapshot)
                    continuation.yield(snapshot)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Restores previously completed purchases, forwarding to the base service.
    /// Persists on success; rethrows on failure (a restore is an explicit user
    /// action, so the plugin keeps the prior state).
    public func restorePurchases() async throws -> EntitlementSnapshot {
        let snapshot = try await base.restorePurchases()
        persist(snapshot)
        return snapshot
    }

    /// Non-throwing read for callers that always want a snapshot, degrading to
    /// free only for a genuinely-unknown user. Convenient for building a
    /// per-request monetization context off the main actor.
    public func currentSnapshot() async -> EntitlementSnapshot {
        (try? await customerInfo()) ?? EntitlementSnapshot()
    }

    // MARK: - Cache

    private func persist(_ snapshot: EntitlementSnapshot) {
        store.setValue(CachedEntitlement(snapshot, cachedAt: now()), for: .lastKnownEntitlement)
    }

    /// Reads the cache in priority order:
    ///
    /// 1. Primary v2 hit → returned as-is; the legacy store is never consulted.
    /// 2. Primary v1 (pre-`cachedAt`) → migrated in place as stale (permanent
    ///    license survives, `isPro` dropped since the capture time is unknown),
    ///    the v1 key removed. Nothing is written under the v2 key until the next
    ///    live success.
    /// 3. Primary miss with a `migratingFrom` store present, legacy v2 hit →
    ///    deleted from the legacy store, written forward into the primary, and
    ///    returned at face value (its own `cachedAt`, so the staleness policy
    ///    still applies).
    /// 4. Legacy v1 → migrated forward as stale exactly like (2), then written
    ///    into the primary and the legacy v1 key removed.
    ///
    /// The one-shot legacy read/delete/write-forward mirrors the primary v1→v2
    /// precedent: the legacy source is consulted once, then emptied.
    private func readCache() -> CachedEntitlement? {
        if let cached = store.value(.lastKnownEntitlement) { return cached }
        if let migrated = migrateV1(from: store, writeForward: false) { return migrated }

        guard let legacyStore else { return nil }
        if let cached = legacyStore.value(.lastKnownEntitlement) {
            legacyStore.removeValue(for: .lastKnownEntitlement)
            store.setValue(cached, for: .lastKnownEntitlement)
            return cached
        }
        return migrateV1(from: legacyStore, writeForward: true)
    }

    /// Reads a v1 (pre-`cachedAt`) payload from `source`, removes it, and returns
    /// the stale-migrated equivalent: permanent license kept, `isPro` dropped
    /// (its capture time is unknown), stamped `.distantPast`. When `writeForward`
    /// is `true` the result is also persisted into the primary store so the
    /// legacy source is emptied for good; the primary-store path leaves the v2
    /// key untouched until the next live success. Returns `nil` on no v1 payload.
    private func migrateV1(
        from source: any KeyValueStore, writeForward: Bool
    ) -> CachedEntitlement? {
        guard let legacy = source.value(legacyV1Key) else { return nil }
        source.removeValue(for: legacyV1Key)
        let migrated = CachedEntitlement(
            isPro: legacy.isPro,
            hasPermanentLicense: legacy.hasPermanentLicense,
            cachedAt: .distantPast
        )
        if writeForward {
            store.setValue(migrated, for: .lastKnownEntitlement)
        }
        return migrated
    }

    /// Applies the staleness policy. Fresh cache: full snapshot. Stale cache
    /// with a permanent license: license kept, `isPro` dropped. Stale
    /// subscription-only cache: `nil` (treated as a cache miss). The age is
    /// compared as `abs(age)` so a wall clock rolled backward can't keep a
    /// cache fresh forever.
    private func usableSnapshot(from cached: CachedEntitlement) -> EntitlementSnapshot? {
        let age = now().timeIntervalSince(cached.cachedAt)
        if abs(age) <= maxCacheAgeInterval {
            return cached.snapshot
        }
        guard cached.hasPermanentLicense else { return nil }
        return EntitlementSnapshot(isPro: false, hasPermanentLicense: true)
    }

    // MARK: - Retry

    /// Exponential backoff with ±20 % jitter: `retryBaseDelay` before attempt
    /// 2, doubling for each attempt after that.
    private func backoffDelay(beforeAttempt attempt: Int) -> Duration {
        let doublings = max(0, attempt - 2)
        let base = Self.interval(of: retryBaseDelay) * pow(2, Double(doublings))
        return .seconds(base * Double.random(in: 0.8...1.2))
    }

    private static func interval(of duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) * 1e-18
    }
}
