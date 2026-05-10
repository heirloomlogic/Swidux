//
//  RefreshPolicy.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Controls how `FeatureFlagsAction.refresh` behaves.
public enum RefreshPolicy: Sendable {
    /// Every `.refresh` triggers a fetch. No debouncing.
    case manual
    /// Debounce against `lastFetchedAt + minInterval`. Default 5 minutes.
    case automatic(minInterval: TimeInterval)

    /// Default automatic policy: 5-minute debounce.
    public static let automatic: RefreshPolicy = .automatic(minInterval: 300)
}
