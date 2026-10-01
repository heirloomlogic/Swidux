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
    /// `false`: undo and redo never roll this slice back; restoring it would latch an in-flight refresh or discard newer config.
    public static var restoresOnUndo: Bool { false }

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

    /// Session-scoped record of every value each flag's exposures have
    /// reported. An exposure is recorded only for a value not already here,
    /// so a reassignment (sign-in, a config change) is recorded once and a
    /// value that comes back is not recorded again. Bounded by the handful of
    /// values a flag can render. Reset on every app launch.
    public var exposedValues: [String: Set<FlagValue>] = [:]

    /// Stable per-install identity used for bucketing when no `userIDKeyPath`
    /// resolves to a non-nil value.
    ///
    /// Seeded at launch by ``hydrated(from:deviceID:defaultConfig:)`` and kept
    /// in sync from the plugin's `deviceIDKeyPath`. Source it from a
    /// `KeychainKeyValueStore` (via `KeyValueStore.deviceIdentity()`) so it
    /// survives reinstall — otherwise the user re-buckets on every fresh
    /// install. Don't write it from app code.
    public var resolvedDeviceID: String = ""

    /// The bucketing identity resolved by the plugin's `userIDKeyPath` —
    /// the current user ID when one is set, else `nil` (which falls back to
    /// ``resolvedDeviceID``). Maintained by ``FeatureFlagsPlugin`` on every
    /// dispatch; don't write it from app code.
    public var resolvedUserID: String? = nil

    /// Creates a state slice with explicit values for every property.
    /// Use ``hydrated(from:deviceID:defaultConfig:)`` for the typical app-launch path.
    public init(
        config: FeatureFlagsConfig = .empty,
        lastFetchedAt: Date? = nil,
        lastFetchError: String? = nil,
        isFetching: Bool = false,
        localOverrides: [String: FlagValue] = [:],
        exposedValues: [String: Set<FlagValue>] = [:],
        resolvedDeviceID: String = "",
        resolvedUserID: String? = nil
    ) {
        self.config = config
        self.lastFetchedAt = lastFetchedAt
        self.lastFetchError = lastFetchError
        self.isFetching = isFetching
        self.localOverrides = localOverrides
        self.exposedValues = exposedValues
        self.resolvedDeviceID = resolvedDeviceID
        self.resolvedUserID = resolvedUserID
    }

    /// Builds an initial state by seeding the bucketing identity and reading
    /// the last-known config from the supplied key-value store.
    ///
    /// Pass the same `deviceID` the app hydrates into `AppState` — mint it once
    /// at launch with `KeychainKeyValueStore.deviceIdentity()` so bucketing is
    /// stable across reinstall and shares the analytics identity. Seeding here
    /// means the very first render (before any dispatch resolves the plugin's
    /// `deviceIDKeyPath`) already buckets correctly.
    public static func hydrated(
        from store: any KeyValueStore,
        deviceID: String,
        defaultConfig: FeatureFlagsConfig? = nil
    ) -> FeatureFlagsState {
        let config: FeatureFlagsConfig =
            store.value(.featureFlagsConfig)
            ?? defaultConfig
            ?? .empty

        return FeatureFlagsState(config: config, resolvedDeviceID: deviceID)
    }
}

extension KVKey where Value == FeatureFlagsConfig {
    /// Last successfully fetched feature-flags config. Hydrated at startup.
    public static let featureFlagsConfig = KVKey<FeatureFlagsConfig>("swidux.featureFlags.config")
}

// MARK: - Read API (shared evaluation)

/// Internal evaluator shared by the reads on ``FeatureFlagsState`` and
/// ``FeatureFlagsStateObserver`` and by exposure recording, so an exposure
/// always reports what the read rendered. Pure functions over the relevant
/// fields; `nil` means the read falls back to the Swift-side default.
enum FlagEvaluator {
    static func isEnabled(
        _ flag: BoolFlag,
        config: FeatureFlagsConfig,
        localOverrides: [String: FlagValue],
        bucketingID: String
    ) -> Bool? {
        if case .bool(let v) = localOverrides[flag.key] { return v }
        guard case .boolean(let rollout) = config.flags[flag.key] else { return nil }
        return Bucketing.isInRollout(
            bucket: Bucketing.bucket(id: bucketingID, flagKey: flag.key), rollout: rollout)
    }

    static func variant<Variant>(
        of flag: VariantFlag<Variant>,
        config: FeatureFlagsConfig,
        localOverrides: [String: FlagValue],
        bucketingID: String
    ) -> Variant? where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
        if case .string(let raw) = localOverrides[flag.key],
            let parsed = Variant(rawValue: raw)
        {
            return parsed
        }
        guard case .variant(let variants) = config.flags[flag.key], !variants.isEmpty else {
            return nil
        }
        let bucket = Bucketing.bucket(id: bucketingID, flagKey: flag.key)
        let index = Bucketing.variantIndex(bucket: bucket, weights: variants.map(\.weight))
        return Variant(rawValue: variants[index].value)
    }

    static func value(
        of flag: ValueFlag<Bool>,
        config: FeatureFlagsConfig,
        localOverrides: [String: FlagValue]
    ) -> Bool? {
        if case .bool(let v) = localOverrides[flag.key] { return v }
        if case .value(.bool(let v)) = config.flags[flag.key] { return v }
        return nil
    }

    static func value(
        of flag: ValueFlag<Int>,
        config: FeatureFlagsConfig,
        localOverrides: [String: FlagValue]
    ) -> Int? {
        if case .int(let v) = localOverrides[flag.key] { return v }
        if case .value(.int(let v)) = config.flags[flag.key] { return v }
        return nil
    }

    static func value(
        of flag: ValueFlag<Double>,
        config: FeatureFlagsConfig,
        localOverrides: [String: FlagValue]
    ) -> Double? {
        // `FlagValue` decodes any whole number — `2.0` included — as `.int`,
        // so a Double read that matched only `.double` would ignore it.
        switch localOverrides[flag.key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: break
        }
        switch config.flags[flag.key] {
        case .value(.double(let v)): return v
        case .value(.int(let v)): return Double(v)
        default: return nil
        }
    }

    static func value(
        of flag: ValueFlag<String>,
        config: FeatureFlagsConfig,
        localOverrides: [String: FlagValue]
    ) -> String? {
        if case .string(let v) = localOverrides[flag.key] { return v }
        if case .value(.string(let v)) = config.flags[flag.key] { return v }
        return nil
    }
}

// MARK: - Read API on the struct

extension FeatureFlagsState {
    /// The identity used for bucketing when the caller doesn't pass one:
    /// the plugin-resolved user ID when present, else the device ID.
    var defaultBucketingID: String { resolvedUserID ?? resolvedDeviceID }

    /// Reads a boolean flag.
    ///
    /// Evaluation order:
    /// 1. Local override (if any),
    /// 2. Remote config (rollout bucketing against `bucketingID`),
    /// 3. Swift-side `default`.
    ///
    /// When `bucketingID` is omitted, the plugin-resolved user ID is used if
    /// the host configured a `userIDKeyPath` and a user is signed in;
    /// otherwise the stable device ID.
    public func isEnabled(
        _ flag: BoolFlag,
        bucketingID: String? = nil,
        default defaultValue: Bool = false
    ) -> Bool {
        FlagEvaluator.isEnabled(
            flag,
            config: config,
            localOverrides: localOverrides,
            bucketingID: bucketingID ?? defaultBucketingID
        ) ?? defaultValue
    }

    /// Reads a variant flag.
    ///
    /// Returns the host's `defaultValue` if the flag is missing or the JSON
    /// ships a string the enum doesn't recognize.
    ///
    /// When `bucketingID` is omitted, the plugin-resolved user ID is used if
    /// the host configured a `userIDKeyPath` and a user is signed in;
    /// otherwise the stable device ID.
    public func variant<Variant>(
        of flag: VariantFlag<Variant>,
        bucketingID: String? = nil
    ) -> Variant where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
        FlagEvaluator.variant(
            of: flag,
            config: config,
            localOverrides: localOverrides,
            bucketingID: bucketingID ?? defaultBucketingID
        ) ?? flag.defaultValue
    }

    /// Reads a value flag (`Bool`).
    public func value(of flag: ValueFlag<Bool>) -> Bool {
        FlagEvaluator.value(of: flag, config: config, localOverrides: localOverrides)
            ?? flag.defaultValue
    }

    /// Reads a value flag (`Int`).
    public func value(of flag: ValueFlag<Int>) -> Int {
        FlagEvaluator.value(of: flag, config: config, localOverrides: localOverrides)
            ?? flag.defaultValue
    }

    /// Reads a value flag (`Double`). A whole-number remote value or override
    /// (`.int`) reads as the equivalent `Double`.
    public func value(of flag: ValueFlag<Double>) -> Double {
        FlagEvaluator.value(of: flag, config: config, localOverrides: localOverrides)
            ?? flag.defaultValue
    }

    /// Reads a value flag (`String`).
    public func value(of flag: ValueFlag<String>) -> String {
        FlagEvaluator.value(of: flag, config: config, localOverrides: localOverrides)
            ?? flag.defaultValue
    }
}

// MARK: - Read API on the observer
//
// Mirrors the struct API so SwiftUI views can call `store.featureFlags.isEnabled(.x)`
// through Swidux's `@dynamicMemberLookup`, which forwards to the observer class.
// Each method reads only the observer fields evaluation needs (`config`,
// `localOverrides`, and the bucketing identity), so a view re-renders when one of
// those changes — any config change, not just one to the flag it reads.

extension FeatureFlagsStateObserver {
    /// The identity used for bucketing when the caller doesn't pass one:
    /// the plugin-resolved user ID when present, else the device ID.
    var defaultBucketingID: String { resolvedUserID ?? resolvedDeviceID }

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
            bucketingID: bucketingID ?? defaultBucketingID
        ) ?? defaultValue
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
            bucketingID: bucketingID ?? defaultBucketingID
        ) ?? flag.defaultValue
    }

    /// Reads a value flag (`Bool`) against the observer's current state.
    public func value(of flag: ValueFlag<Bool>) -> Bool {
        FlagEvaluator.value(of: flag, config: config, localOverrides: localOverrides)
            ?? flag.defaultValue
    }

    /// Reads a value flag (`Int`) against the observer's current state.
    public func value(of flag: ValueFlag<Int>) -> Int {
        FlagEvaluator.value(of: flag, config: config, localOverrides: localOverrides)
            ?? flag.defaultValue
    }

    /// Reads a value flag (`Double`) against the observer's current state.
    /// A whole-number remote value or override (`.int`) reads as a `Double`.
    public func value(of flag: ValueFlag<Double>) -> Double {
        FlagEvaluator.value(of: flag, config: config, localOverrides: localOverrides)
            ?? flag.defaultValue
    }

    /// Reads a value flag (`String`) against the observer's current state.
    public func value(of flag: ValueFlag<String>) -> String {
        FlagEvaluator.value(of: flag, config: config, localOverrides: localOverrides)
            ?? flag.defaultValue
    }
}
