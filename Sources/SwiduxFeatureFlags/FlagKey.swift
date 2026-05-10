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
    public let key: String
    public init(_ key: String) { self.key = key }
}

/// Typed key for a variant (A/B) flag.
///
/// `Variant` must be `RawRepresentable<String>` so the wire-format string
/// decodes into the host's enum. If the JSON ships a variant the enum
/// doesn't know about, reads return `defaultValue` — fail-safe by construction.
public struct VariantFlag<Variant>: Sendable
where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
    public let key: String
    public let defaultValue: Variant
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
    public let key: String
    public let defaultValue: Value
    public init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }
}
