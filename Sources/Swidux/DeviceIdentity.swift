//
//  DeviceIdentity.swift
//  Swidux
//
//  Shared read-or-mint helper for a stable, anonymous per-install identity.
//

import Foundation

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
    /// Returns a stable per-install identity, minting and persisting a fresh
    /// UUID string only when the Keychain confirms none exists.
    ///
    /// This overload takes priority over ``KeyValueStore/deviceIdentity(key:)``
    /// for a concrete `KeychainKeyValueStore` (the way every guide constructs
    /// and calls it — `KeychainKeyValueStore(service:).deviceIdentity()`).
    /// It exists because the generic version can't tell "no identity yet"
    /// apart from "couldn't read the identity right now": a locked keychain
    /// before first unlock (`errSecInteractionNotAllowed`) or an item that
    /// exists but fails to decode. Minting in either of those cases would
    /// silently overwrite an existing identity through the
    /// duplicate-then-update path in ``setValue(_:for:)``. Instead, this
    /// returns a session-only identity and leaves the Keychain untouched —
    /// the next call, once the item can actually be read, returns the real one.
    ///
    /// - Parameter key: The key to read/write. Defaults to ``KVKey/deviceID``.
    /// - Returns: The existing identity; a freshly minted-and-persisted one if
    ///   none exists yet; or an unpersisted, session-only one if an existing
    ///   item couldn't be read.
    public func deviceIdentity(key: KVKey<String> = .deviceID) -> String {
        switch lookup(key) {
        case .found(let existing):
            return existing
        case .failed:
            return UUID().uuidString
        case .missing:
            let minted = UUID().uuidString
            guard setValue(minted, for: key) else { return minted }
            return value(key) ?? minted
        }
    }
}
