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
    /// read it right now": a locked keychain before first unlock
    /// (`errSecInteractionNotAllowed`), or an item that exists but fails to
    /// decode. Minting in either case would overwrite the real identity through
    /// the duplicate-then-update path in ``setValue(_:for:)``. Instead this
    /// returns a session-only identity and leaves the Keychain untouched, so
    /// the next launch that can read the item gets the real one back.
    func keychainDeviceIdentity(key: KVKey<String>) -> String {
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
