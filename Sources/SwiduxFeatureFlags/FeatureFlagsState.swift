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
    public var config: FeatureFlagsConfig = .empty

    /// Timestamp of the last successful fetch. `nil` until first fetch.
    public var lastFetchedAt: Date? = nil

    /// Last fetch error message — for debug UI only, never user-facing.
    public var lastFetchError: String? = nil

    /// `true` while a refresh effect is in flight.
    public var isFetching: Bool = false

    /// Local overrides — beat remote evaluation.
    public var localOverrides: [String: FlagValue] = [:]

    /// Session-scoped set of flags whose exposure has already been recorded.
    /// Reset on every app launch.
    public var exposedKeys: Set<String> = []

    /// Stable per-install identity used for bucketing when no `userIDKeyPath`
    /// resolves to a non-nil value.
    public var installID: UUID = UUID()

    /// Creates a state slice with explicit values for every property.
    /// Use ``hydrated(from:defaultConfig:)`` for the typical app-launch path.
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

// MARK: - Read API (shared evaluation)

/// Internal evaluator shared by ``FeatureFlagsState`` and
/// ``FeatureFlagsStateObserver``. Pure functions over the relevant fields.
enum FlagEvaluator {
    static func isEnabled(
        _ flag: BoolFlag,
        config: FeatureFlagsConfig,
        localOverrides: [String: FlagValue],
        bucketingID: String,
        default defaultValue: Bool
    ) -> Bool {
        if case .bool(let v) = localOverrides[flag.key] { return v }
        guard case .boolean(let rollout) = config.flags[flag.key] else {
            return defaultValue
        }
        if rollout >= 100 { return true }
        if rollout <= 0 { return false }
        return Bucketing.bucket(id: bucketingID, flagKey: flag.key) < rollout
    }

    static func variant<Variant>(
        of flag: VariantFlag<Variant>,
        config: FeatureFlagsConfig,
        localOverrides: [String: FlagValue],
        bucketingID: String
    ) -> Variant where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
        if case .string(let raw) = localOverrides[flag.key],
            let parsed = Variant(rawValue: raw)
        {
            return parsed
        }
        guard case .variant(let variants) = config.flags[flag.key], !variants.isEmpty else {
            return flag.defaultValue
        }
        let bucket = Bucketing.bucket(id: bucketingID, flagKey: flag.key)
        let index = Bucketing.variantIndex(bucket: bucket, weights: variants.map(\.weight))
        return Variant(rawValue: variants[index].value) ?? flag.defaultValue
    }
}

// MARK: - Read API on the struct

extension FeatureFlagsState {
    /// Reads a boolean flag.
    ///
    /// Evaluation order:
    /// 1. Local override (if any),
    /// 2. Remote config (rollout bucketing against `bucketingID`),
    /// 3. Swift-side `default`.
    public func isEnabled(
        _ flag: BoolFlag,
        bucketingID: String? = nil,
        default defaultValue: Bool = false
    ) -> Bool {
        FlagEvaluator.isEnabled(
            flag,
            config: config,
            localOverrides: localOverrides,
            bucketingID: bucketingID ?? installID.uuidString,
            default: defaultValue
        )
    }

    /// Reads a variant flag.
    ///
    /// Returns the host's `defaultValue` if the flag is missing or the JSON
    /// ships a string the enum doesn't recognize.
    public func variant<Variant>(
        of flag: VariantFlag<Variant>,
        bucketingID: String? = nil
    ) -> Variant where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
        FlagEvaluator.variant(
            of: flag,
            config: config,
            localOverrides: localOverrides,
            bucketingID: bucketingID ?? installID.uuidString
        )
    }

    /// Reads a value flag (`Bool`).
    public func value(of flag: ValueFlag<Bool>) -> Bool {
        if case .bool(let v) = localOverrides[flag.key] { return v }
        if case .value(.bool(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }

    /// Reads a value flag (`Int`).
    public func value(of flag: ValueFlag<Int>) -> Int {
        if case .int(let v) = localOverrides[flag.key] { return v }
        if case .value(.int(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }

    /// Reads a value flag (`Double`).
    public func value(of flag: ValueFlag<Double>) -> Double {
        if case .double(let v) = localOverrides[flag.key] { return v }
        if case .value(.double(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }

    /// Reads a value flag (`String`).
    public func value(of flag: ValueFlag<String>) -> String {
        if case .string(let v) = localOverrides[flag.key] { return v }
        if case .value(.string(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }
}

// MARK: - Read API on the observer
//
// Mirrors the struct API so SwiftUI views can call `store.featureFlags.isEnabled(.x)`
// through Swidux's `@dynamicMemberLookup`, which forwards to the observer class.
// Granular observation is preserved because each method reads only the observer
// fields needed for that flag's evaluation.

extension FeatureFlagsStateObserver {
    /// Reads a boolean flag against the observer's current state.
    public func isEnabled(
        _ flag: BoolFlag,
        bucketingID: String? = nil,
        default defaultValue: Bool = false
    ) -> Bool {
        FlagEvaluator.isEnabled(
            flag,
            config: config,
            localOverrides: localOverrides,
            bucketingID: bucketingID ?? installID.uuidString,
            default: defaultValue
        )
    }

    /// Reads a variant flag against the observer's current state.
    public func variant<Variant>(
        of flag: VariantFlag<Variant>,
        bucketingID: String? = nil
    ) -> Variant where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
        FlagEvaluator.variant(
            of: flag,
            config: config,
            localOverrides: localOverrides,
            bucketingID: bucketingID ?? installID.uuidString
        )
    }

    /// Reads a value flag (`Bool`) against the observer's current state.
    public func value(of flag: ValueFlag<Bool>) -> Bool {
        if case .bool(let v) = localOverrides[flag.key] { return v }
        if case .value(.bool(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }

    /// Reads a value flag (`Int`) against the observer's current state.
    public func value(of flag: ValueFlag<Int>) -> Int {
        if case .int(let v) = localOverrides[flag.key] { return v }
        if case .value(.int(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }

    /// Reads a value flag (`Double`) against the observer's current state.
    public func value(of flag: ValueFlag<Double>) -> Double {
        if case .double(let v) = localOverrides[flag.key] { return v }
        if case .value(.double(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }

    /// Reads a value flag (`String`) against the observer's current state.
    public func value(of flag: ValueFlag<String>) -> String {
        if case .string(let v) = localOverrides[flag.key] { return v }
        if case .value(.string(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }
}
