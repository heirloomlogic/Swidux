//
//  FeatureFlagsConfig.swift
//  SwiduxFeatureFlags
//

import Foundation

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
        self.flags = try container.decode([String: FlagDefinition].self, forKey: .flags)
    }

    private enum CodingKeys: String, CodingKey { case version, flags }
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

    private enum CodingKeys: String, CodingKey { case type, rollout, variants, value }

    /// Decodes a flag definition by branching on the `type` discriminator.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "boolean":
            let rollout = try container.decode(Int.self, forKey: .rollout)
            self = .boolean(rollout: rollout)
        case "variant":
            let variants = try container.decode([Variant].self, forKey: .variants)
            self = .variant(variants: variants)
        case "value":
            let value = try container.decode(FlagValue.self, forKey: .value)
            self = .value(value)
        default:
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
            try container.encode("boolean", forKey: .type)
            try container.encode(rollout, forKey: .rollout)
        case .variant(let variants):
            try container.encode("variant", forKey: .type)
            try container.encode(variants, forKey: .variants)
        case .value(let value):
            try container.encode("value", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}
