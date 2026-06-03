//
//  SyncModePreference.swift
//  SwiduxCloudKitSync
//
//  Persists the user's sync choice and reads it at launch, before the
//  container is built (the mode determines the ModelConfiguration).
//

import Swidux
import SwiduxPersistence

extension KVKey where Value == SyncMode {
    /// The persisted sync preference. Store in `UserDefaults` (not Keychain) —
    /// a fresh install should default per ``resolveDesiredSyncMode(from:default:)``.
    public static var syncMode: KVKey<SyncMode> { KVKey<SyncMode>("swidux.persistence.syncMode") }
}

/// Reads the user's desired sync mode at launch.
///
/// Default is `.iCloud` for apps that link `SwiduxCloudKitSync` (sync-on with
/// opt-out). Pass `.localOnly` to make sync strictly opt-in instead.
public func resolveDesiredSyncMode(
    from store: any KeyValueStore,
    default defaultMode: SyncMode = .iCloud
) -> SyncMode {
    store.value(.syncMode) ?? defaultMode
}
