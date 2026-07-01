//
//  ResilientPaywallService.swift
//  SwiduxPaywall
//

import Swidux

/// `Codable` mirror of ``EntitlementSnapshot`` (which is not `Codable`) so the
/// last-known-good entitlement can be persisted through a ``KeyValueStore``.
public struct CachedEntitlement: Codable, Sendable, Equatable {
    /// `true` when the user had an active pro subscription at the time of caching.
    public var isPro: Bool
    /// `true` when the user owned a permanent/lifetime license at the time of caching.
    public var hasPermanentLicense: Bool

    /// Creates a cached entitlement with the given status.
    public init(isPro: Bool, hasPermanentLicense: Bool) {
        self.isPro = isPro
        self.hasPermanentLicense = hasPermanentLicense
    }

    /// Captures the entitlement status of `snapshot`.
    public init(_ snapshot: EntitlementSnapshot) {
        self.isPro = snapshot.isPro
        self.hasPermanentLicense = snapshot.hasPermanentLicense
    }

    /// The equivalent ``EntitlementSnapshot``.
    public var snapshot: EntitlementSnapshot {
        EntitlementSnapshot(isPro: isPro, hasPermanentLicense: hasPermanentLicense)
    }
}

extension KVKey where Value == CachedEntitlement {
    /// The last entitlement snapshot a successful read delivered. Versioned so a
    /// future shape change declares a new key rather than silently failing to
    /// decode (``KeyValueStore`` has no migration).
    public static let lastKnownEntitlement = KVKey<CachedEntitlement>(
        "swidux.paywall.lastKnownEntitlement.v1"
    )
}

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
/// Provider-agnostic by construction — it speaks only ``PaywallService``, so it
/// wraps any base (simulated, RevenueCat, StoreKit, …). Feed the wrapped instance
/// to *both* ``PaywallPlugin`` and any app-side reader that builds a
/// monetization/context payload from entitlements:
///
/// ```swift
/// let resilient = ResilientPaywallService(base: paywallService, store: UserDefaultsKeyValueStore())
/// // PaywallPlugin(..., service: resilient)   // gate + account display
/// // await resilient.currentSnapshot()        // server payload, off-main
/// ```
public struct ResilientPaywallService: PaywallService {
    private let base: any PaywallService
    private let store: any KeyValueStore
    /// Total attempts at a live `customerInfo()` read before falling back to cache.
    private let maxAttempts: Int
    /// When `true`, ``customerInfoStream()`` yields the persisted last-known-good
    /// before live data so a flaky launch never gates a paid user as free. Causes a
    /// brief flash of the prior entitlement on a genuine downgrade; on by default.
    private let seedsFromCache: Bool

    /// Creates a resilient decorator around `base`, persisting last-known-good
    /// through `store`.
    public init(
        base: any PaywallService,
        store: any KeyValueStore,
        maxAttempts: Int = 2,
        seedsFromCache: Bool = true
    ) {
        self.base = base
        self.store = store
        self.maxAttempts = maxAttempts
        self.seedsFromCache = seedsFromCache
    }

    /// Fetches the current entitlement status, retrying up to `maxAttempts`. On
    /// success persists and returns; if every attempt fails, returns the cached
    /// last-known-good when present, otherwise rethrows (so the plugin's honest
    /// `.refreshFailed` path is preserved for a genuinely-unknown user).
    public func customerInfo() async throws -> EntitlementSnapshot {
        var lastError: (any Error)?
        for _ in 1...max(1, maxAttempts) {
            do {
                let snapshot = try await base.customerInfo()
                persist(snapshot)
                return snapshot
            } catch {
                lastError = error
            }
        }
        // Every attempt failed — fall back to the last-known-good so a
        // previously-seen paid user is never dropped to free. With nothing ever
        // cached the user is genuinely unknown: surface the failure honestly.
        if let cached = store.value(.lastKnownEntitlement) {
            return cached.snapshot
        }
        throw lastError ?? CancellationError()
    }

    /// Long-lived stream of entitlement updates. Yields the persisted
    /// last-known-good first (when ``seedsFromCache`` is on), then forwards and
    /// persists every snapshot the base stream emits.
    public func customerInfoStream() -> AsyncStream<EntitlementSnapshot> {
        let base = self.base
        let store = self.store
        let seedsFromCache = self.seedsFromCache
        return AsyncStream { continuation in
            // Seed with the last-known-good so a flaky launch never leaves a paid
            // user gated as free before the live snapshot arrives.
            if seedsFromCache, let cached = store.value(.lastKnownEntitlement) {
                continuation.yield(cached.snapshot)
            }
            let task = Task {
                for await snapshot in base.customerInfoStream() {
                    store.setValue(CachedEntitlement(snapshot), for: .lastKnownEntitlement)
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

    private func persist(_ snapshot: EntitlementSnapshot) {
        store.setValue(CachedEntitlement(snapshot), for: .lastKnownEntitlement)
    }
}
