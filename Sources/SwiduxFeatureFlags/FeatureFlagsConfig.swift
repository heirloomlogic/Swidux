//
//  FeatureFlagsConfig.swift
//  SwiduxFeatureFlags
//

import Foundation
import os

/// Logs flag entries this build cannot decode.
private let logger = Logger(subsystem: "swidux", category: "featureflags")

/// Wire-format root for a Swidux feature-flags JSON config.
///
/// Apps host the JSON wherever they like (CDN, Worker, file server) and
/// point the ``HTTPFeatureFlagsService`` at the URL. The plugin caches the
/// last successful fetch in `KeyValueStore` and falls back to it on failure.
public struct FeatureFlagsConfig: Sendable, Equatable, Codable {
    /// Schema version. Currently `1`. Plugin rejects unknown versions.
    public let version: Int

    /// Flag definitions keyed by stable string key.
    public let flags: [String: FlagDefinition]

    /// An empty config — no flags. Used as initial state and as a safe fallback.
    public static let empty = FeatureFlagsConfig(version: 1, flags: [:])

    /// Creates a config with the given version and flag definitions.
    public init(version: Int = 1, flags: [String: FlagDefinition]) {
        self.version = version
        self.flags = flags
    }

    /// Decodes a wire-format config. Throws if `version` is not `1`.
    ///
    /// Each entry in `flags` decodes on its own. An entry whose `type` this
    /// build doesn't know, typically one added by a newer schema, is dropped
    /// and logged at error level, and the rest of the document still applies.
    /// A known type with a malformed body, or an entry with no `type`, throws
    /// and rejects the whole document.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "unsupported feature-flags config version \(version)"
            )
        }
        self.version = version
        let entries = try container.decode([String: Entry].self, forKey: .flags)
        for (key, entry) in entries where entry.definition == nil {
            logger.error(
                """
                Feature flag \(key, privacy: .public) has unknown type \
                \(entry.type, privacy: .public) and is skipped.
                """
            )
        }
        self.flags = entries.compactMapValues(\.definition)
    }

    private enum CodingKeys: String, CodingKey { case version, flags }

    /// One `flags` entry, decoded as a ``FlagDefinition`` only when this build
    /// knows its `type`.
    private struct Entry: Decodable {
        let type: String
        let definition: FlagDefinition?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: FlagDefinition.CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            guard FlagDefinition.Kind(rawValue: type) != nil else {
                definition = nil
                return
            }
            definition = try FlagDefinition(from: decoder)
        }
    }
}

/// One flag's definition in the wire format.
///
/// Three shapes: boolean rollout, weighted variants, and remote-config
/// scalar values.
public enum FlagDefinition: Sendable, Equatable, Codable {
    /// Boolean flag with rollout percentage (0–100). 0 = off everyone,
    /// 100 = on everyone, in between = stable rollout bucket.
    case boolean(rollout: Int)
    /// Weighted variant assignment. Weights must sum to 100.
    case variant(variants: [Variant])
    /// Remote-config scalar value.
    case value(FlagValue)

    /// One weighted choice in a variant flag.
    public struct Variant: Sendable, Equatable, Codable {
        /// Raw string value decoded into the host's variant enum.
        public let value: String
        /// Weight in `0...100`. Sum of variants must equal `100`.
        public let weight: Int

        /// Creates a variant entry.
        public init(value: String, weight: Int) {
            self.value = value
            self.weight = weight
        }
    }

    fileprivate enum CodingKeys: String, CodingKey { case type, rollout, variants, value }

    /// The `type` discriminators this build decodes.
    fileprivate enum Kind: String { case boolean, variant, value }

    /// Decodes a flag definition by branching on the `type` discriminator.
    ///
    /// Throws on a `type` this build doesn't know. ``FeatureFlagsConfig``
    /// skips such entries instead of rejecting the document.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch Kind(rawValue: type) {
        case .boolean:
            let rollout = try container.decode(Int.self, forKey: .rollout)
            guard (0...100).contains(rollout) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .rollout, in: container,
                    debugDescription: "boolean rollout must be in 0...100")
            }
            self = .boolean(rollout: rollout)
        case .variant:
            let variants = try container.decode([Variant].self, forKey: .variants)
            // Reject malformed variant sets at the wire boundary: an empty
            // array has nothing to assign, negative weights corrupt the
            // cumulative walk, and weights that don't sum to 100 silently
            // skew every assignment toward the last variant. Throwing here
            // keeps the plugin on its cached config instead.
            guard !variants.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .variants,
                    in: container,
                    debugDescription: "variant flag has no variants"
                )
            }
            guard variants.allSatisfy({ (0...100).contains($0.weight) }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .variants,
                    in: container,
                    debugDescription: "variant weights must be in 0...100"
                )
            }
            // Saturate at the first invalid total; even an arbitrarily large
            // decoded array cannot overflow the accumulator.
            let total = variants.reduce(0) { min(101, $0 + $1.weight) }
            guard total == 100 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .variants,
                    in: container,
                    debugDescription: "variant weights must sum to 100 (got \(total))"
                )
            }
            self = .variant(variants: variants)
        case .value:
            let value = try container.decode(FlagValue.self, forKey: .value)
            self = .value(value)
        case nil:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown flag type \(type)"
            )
        }
    }

    /// Encodes the flag definition with its `type` discriminator.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .boolean(let rollout):
            try container.encode(Kind.boolean.rawValue, forKey: .type)
            try container.encode(rollout, forKey: .rollout)
        case .variant(let variants):
            try container.encode(Kind.variant.rawValue, forKey: .type)
            try container.encode(variants, forKey: .variants)
        case .value(let value):
            try container.encode(Kind.value.rawValue, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}
