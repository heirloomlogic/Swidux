//
//  DeviceIdentity.swift
//  Swidux
//
//  Shared read-or-mint helper for a stable, anonymous per-install identity.
//

import Foundation
import Synchronization

extension KVKey where Value == String {
    /// Stable, anonymous per-install identity.
    ///
    /// Back this with a ``KeychainKeyValueStore`` so the identity survives app
    /// reinstall. Hydrate it once at launch into `AppState` and use it for both
    /// `AnalyticsIdentity(userID: \.deviceID, …)` and feature-flag bucketing —
    /// one identity, so A/B exposure correlates with the user analytics reports
    /// against.
    public static let deviceID = KVKey<String>("swidux.deviceID")
}

extension KeyValueStore {
    /// Returns a stable per-install identity, minting and persisting a fresh
    /// UUID string on first call.
    ///
    /// Call this **once** at launch on a ``KeychainKeyValueStore`` so the value
    /// survives reinstall, then hydrate it into `AppState`. A `UserDefaults`-backed
    /// store works but regenerates on reinstall — which silently re-buckets
    /// feature-flag assignments and breaks anonymous analytics continuity, so it
    /// is not recommended for identity.
    ///
    /// ```swift
    /// let kv = KeychainKeyValueStore(service: "com.example.myapp")
    /// let deviceID = kv.deviceIdentity()
    /// let initial = AppState(deviceID: deviceID, …)
    /// ```
    ///
    /// Call before spawning concurrency: two concurrent *first* calls can both
    /// mint, and the racers may observe different values for that one session.
    /// The persisted value is re-read after writing so the stored identity is
    /// authoritative from the next read on.
    ///
    /// - Parameter key: The key to read/write. Defaults to ``KVKey/deviceID``.
    /// - Returns: The existing identity, or a freshly minted-and-persisted one.
    public func deviceIdentity(key: KVKey<String> = .deviceID) -> String {
        // Dispatched at runtime, not by overload, so an app that holds its
        // store as `any KeyValueStore` still gets the Keychain's distinction
        // between "no identity yet" and "couldn't read it right now".
        if let keychain = self as? KeychainKeyValueStore {
            return keychain.keychainDeviceIdentity(key: key)
        }
        if let existing = value(key) { return existing }
        let minted = UUID().uuidString
        // A store that couldn't persist won't have anything to read back, so
        // skip the round trip and use the minted value for this session. An
        // unsigned or unentitled build takes this path — see `KeychainKeyValueStore`.
        guard setValue(minted, for: key) else { return minted }
        return value(key) ?? minted
    }
}

extension KeychainKeyValueStore {
    /// Mints and persists an identity only when the Keychain confirms none
    /// exists.
    ///
    /// The generic read-or-mint can't tell "no identity yet" from "couldn't
    /// read it right now" — and, among read failures, can't tell "couldn't
    /// read it *right now*" from "will never read as `String` again."
    /// Minting over either would overwrite the real identity through the
    /// duplicate-then-update path in ``setValue(_:for:)``:
    ///
    /// - **`.unreadable`** (a locked keychain before first unlock, a missing
    ///   entitlement) is transient — a later call, once the environment
    ///   changes, can read the same item. Mint a session-only identity
    ///   without writing, so the next call that *can* read gets the real one
    ///   back. Repeated calls in this process agree with each other (see
    ///   `sessionIdentity`), so a session that calls this more than once —
    ///   once for analytics, once for feature-flag bucketing — doesn't
    ///   fragment into two device identities for the same launch.
    /// - **`.undecodable`** is permanent — the same bytes fail to decode
    ///   every time, most commonly a plain UTF-8 string written by an
    ///   earlier, hand-rolled version of this helper, before this JSON-encoded
    ///   shape existed. Treating this like `.unreadable` mints a *different*
    ///   session-only identity on every call and every launch, forever —
    ///   strictly worse than the one-time overwrite this replaced. Recover
    ///   the value if it looks like a plain identity string and migrate it to
    ///   the JSON encoding; otherwise the item is garbage, so mint fresh and
    ///   overwrite it — that's still a one-time cost, not a per-launch one.
    func keychainDeviceIdentity(key: KVKey<String>) -> String {
        switch lookup(key) {
        case .found(let existing):
            return existing
        case .undecodable(let data):
            if let recovered = Self.recoverIdentity(fromUndecodable: data) {
                setValue(recovered, for: key)
                return recovered
            }
            let minted = UUID().uuidString
            guard setValue(minted, for: key) else { return minted }
            return value(key) ?? minted
        case .unreadable:
            return sessionIdentity(for: key)
        case .missing:
            let minted = UUID().uuidString
            guard setValue(minted, for: key) else { return minted }
            return value(key) ?? minted
        }
    }

    /// Attempts to recover an identity from a Keychain item that failed to
    /// decode as JSON — most often a plain UTF-8 string an earlier,
    /// hand-rolled wrapper wrote directly, before ``deviceIdentity(key:)``
    /// existed. Returns the recovered identity, or `nil` if the bytes don't
    /// look like one, in which case the caller should treat the item as
    /// unrecoverable and overwrite it.
    ///
    /// Pure and Keychain-free: this is the seam covered by
    /// `RecoverIdentityTests`, which exercise it directly without touching
    /// the Keychain.
    ///
    /// - Parameter data: The raw bytes an undecodable item holds.
    /// - Returns: The recovered identity, or `nil`.
    static func recoverIdentity(fromUndecodable data: Data) -> String? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, UUID(uuidString: trimmed) != nil else { return nil }
        return trimmed
    }

    /// A per-process, per-store-location cache of minted session-only
    /// identities, so repeated `.unreadable` calls for the same key agree
    /// with each other for the life of the process — instead of each call
    /// minting its own UUID, which would let analytics and feature-flag
    /// bucketing diverge within a single launch.
    private static let sessionIdentities = Mutex<[String: String]>([:])

    /// Returns this process's session-only identity for `key`, minting one
    /// on first use and remembering it for later calls against the same
    /// store location — see ``sessionIdentities``.
    ///
    /// Not `private`: this is the seam `SessionIdentityTests` calls
    /// directly, bypassing `lookup(_:)`, so the memoization itself is
    /// unit-testable without ever reaching the Keychain — including on a
    /// host where `.unreadable` can't be produced (see the type's own
    /// `.unreadable`/`.missing` distinction in ``LookupResult``).
    func sessionIdentity(for key: KVKey<String>) -> String {
        let cacheKey = "\(storeIdentity)|\(key.name)"
        return Self.sessionIdentities.withLock { cache in
            if let cached = cache[cacheKey] { return cached }
            let minted = UUID().uuidString
            cache[cacheKey] = minted
            return minted
        }
    }
}
