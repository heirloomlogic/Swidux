//
//  FeatureFlagsState.swift
//  SwiduxFeatureFlags
//

import Foundation
import Swidux

/// State slice owned by ``FeatureFlagsPlugin``.
///
/// Hosted in the app's root state via `@Slice var featureFlags: FeatureFlagsState`.
@Swidux
public nonisolated struct FeatureFlagsState: Equatable, Sendable {
    /// Last successfully fetched (or hydrated) config.
    public var config: FeatureFlagsConfig

    /// Timestamp of the last successful fetch. `nil` until first fetch.
    public var lastFetchedAt: Date?

    /// Last fetch error message — for debug UI only, never user-facing.
    public var lastFetchError: String?

    /// `true` while a refresh effect is in flight.
    public var isFetching: Bool

    /// Local overrides — beat remote evaluation.
    public var localOverrides: [String: FlagValue]

    /// Session-scoped set of flags whose exposure has already been recorded.
    /// Reset on every app launch.
    public var exposedKeys: Set<String>

    /// Stable per-install identity used for bucketing when no `userIDKeyPath`
    /// resolves to a non-nil value.
    public var installID: UUID

    public init(
        config: FeatureFlagsConfig = .empty,
        lastFetchedAt: Date? = nil,
        lastFetchError: String? = nil,
        isFetching: Bool = false,
        localOverrides: [String: FlagValue] = [:],
        exposedKeys: Set<String> = [],
        installID: UUID = UUID()
    ) {
        self.config = config
        self.lastFetchedAt = lastFetchedAt
        self.lastFetchError = lastFetchError
        self.isFetching = isFetching
        self.localOverrides = localOverrides
        self.exposedKeys = exposedKeys
        self.installID = installID
    }

    /// Builds an initial state by reading the install ID and last-known
    /// config from the supplied key-value store. Generates and persists a
    /// new install ID if none is stored.
    public static func hydrated(
        from store: any KeyValueStore,
        defaultConfig: FeatureFlagsConfig? = nil
    ) -> FeatureFlagsState {
        let installID: UUID
        if let stored: String = store.value(.featureFlagsInstallID),
            let uuid = UUID(uuidString: stored)
        {
            installID = uuid
        } else {
            installID = UUID()
            store.setValue(installID.uuidString, for: .featureFlagsInstallID)
        }

        let config: FeatureFlagsConfig =
            store.value(.featureFlagsConfig)
            ?? defaultConfig
            ?? .empty

        return FeatureFlagsState(config: config, installID: installID)
    }
}

extension KVKey where Value == String {
    /// Install-scoped UUID used for bucketing. Persisted on first generation.
    public static let featureFlagsInstallID = KVKey<String>("swidux.featureFlags.installID")
}

extension KVKey where Value == FeatureFlagsConfig {
    /// Last successfully fetched feature-flags config. Hydrated at startup.
    public static let featureFlagsConfig = KVKey<FeatureFlagsConfig>("swidux.featureFlags.config")
}
