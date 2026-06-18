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
    /// - Parameter key: The key to read/write. Defaults to ``KVKey/deviceID``.
    /// - Returns: The existing identity, or a freshly minted-and-persisted one.
    public func deviceIdentity(key: KVKey<String> = .deviceID) -> String {
        if let existing = value(key) { return existing }
        let minted = UUID().uuidString
        setValue(minted, for: key)
        return minted
    }
}
