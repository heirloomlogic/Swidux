//
//  FeatureFlagsAction.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Actions handled by ``FeatureFlagsPlugin``.
public enum FeatureFlagsAction: Sendable, Equatable {
    /// Trigger a fetch. Debounced against `lastFetchedAt + minInterval`
    /// when the plugin's `refreshPolicy` is `.automatic`.
    case refresh

    /// Service returned a fresh config. Plugin updates state and persists
    /// to `KeyValueStore`.
    case refreshSucceeded(FeatureFlagsConfig, fetchedAt: Date)

    /// Service threw. Plugin keeps last-known-good config.
    case refreshFailed(String)

    /// Set a local override that beats remote evaluation.
    case setLocalOverride(key: String, value: FlagValue)

    /// Remove a single local override.
    case clearLocalOverride(key: String)

    /// Remove all local overrides.
    case clearAllLocalOverrides

    /// Record that a flag was applied to the user (variant shown).
    /// Plugin dedupes per session and fires the optional `onExposure` callback.
    case recordExposure(key: String)
}
