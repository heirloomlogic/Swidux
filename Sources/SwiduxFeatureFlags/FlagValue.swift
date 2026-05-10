//
//  FlagValue.swift
//  SwiduxFeatureFlags
//

import Foundation

/// A typed value for a feature flag — boolean, integer, double, or string.
///
/// Closed enum so the wire format and evaluation paths can never produce a
/// runtime `Any`. Constructed by decoding the JSON wire format or supplied
/// programmatically as a local override.
public enum FlagValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
            return
        }
        if let v = try? container.decode(Int.self) {
            self = .int(v)
            return
        }
        if let v = try? container.decode(Double.self) {
            self = .double(v)
            return
        }
        if let v = try? container.decode(String.self) {
            self = .string(v)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "FlagValue must be Bool, Int, Double, or String"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }
}
