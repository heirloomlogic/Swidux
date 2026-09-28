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
    ///
    /// Knows only the key, so it records the remote assignment whether or
    /// not the app could render it, and always buckets by the default
    /// identity.
    @available(
        *, deprecated,
        message: "Records values the user may not have seen. Use recordExposure(of:) with the typed flag."
    )
    case recordExposure(key: String)

    /// Record that the user was shown the value a typed read rendered.
    /// Build it with a `recordExposure(of:)` factory. The plugin fires the
    /// optional `onExposure` callback once per session for each distinct
    /// value a flag renders.
    case recordFlagExposure(FlagExposure)
}
