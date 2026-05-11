//
//  FlagKey.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Typed key for a boolean feature flag.
///
/// Declare these once on the host's namespace, then read with
/// `store.featureFlags.isEnabled(.myFlag)`.
public struct BoolFlag: Sendable, Hashable {
    /// Wire-format key matching a `boolean` entry in the JSON config.
    public let key: String
    /// Creates a typed boolean-flag key.
    public init(_ key: String) { self.key = key }
}

/// Typed key for a variant (A/B) flag.
///
/// `Variant` must be `RawRepresentable<String>` so the wire-format string
/// decodes into the host's enum. If the JSON ships a variant the enum
/// doesn't know about, reads return `defaultValue` — fail-safe by construction.
public struct VariantFlag<Variant>: Sendable
where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
    /// Wire-format key matching a `variant` entry in the JSON config.
    public let key: String
    /// Returned when the flag is missing or the JSON variant doesn't match the enum.
    public let defaultValue: Variant
    /// Creates a typed variant-flag key with a fail-safe default.
    public init(_ key: String, default defaultValue: Variant) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

/// Typed key for a remote-tunable scalar value flag.
///
/// `Value` must be one of the four ``FlagValue`` payload types (`Bool`,
/// `Int`, `Double`, `String`). The plugin's read API enforces this via
/// overloads on ``FeatureFlagsState``.
public struct ValueFlag<Value: Sendable>: Sendable {
    /// Wire-format key matching a `value` entry in the JSON config.
    public let key: String
    /// Returned when the flag is missing or its type doesn't match `Value`.
    public let defaultValue: Value
    /// Creates a typed value-flag key with a fail-safe default.
    public init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }
}
