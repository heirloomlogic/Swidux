//
//  AnalyticsValue.swift
//  SwiduxAnalytics
//

import Foundation

/// Provider-agnostic property value for analytics events and user identity.
///
/// Closed enum so service adapters (Mixpanel, Amplitude, etc.) can map
/// deterministically to native types without runtime `Any` surprises.
///
/// Construction is kept ergonomic via `ExpressibleBy*Literal` conformances:
///
/// ```swift
/// let props: [String: AnalyticsValue] = [
///     "amount": 5,          // .int(5)
///     "tier": "pro",        // .string("pro")
///     "active": true,       // .bool(true)
///     "tags": ["a", "b"],   // .array([.string("a"), .string("b")])
/// ]
/// ```
public enum AnalyticsValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case array([AnalyticsValue])
    case dict([String: AnalyticsValue])
    case null
}

extension AnalyticsValue: ExpressibleByStringLiteral {
    /// Wraps a string literal as `.string`.
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension AnalyticsValue: ExpressibleByIntegerLiteral {
    /// Wraps an integer literal as `.int`.
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension AnalyticsValue: ExpressibleByFloatLiteral {
    /// Wraps a float literal as `.double`.
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension AnalyticsValue: ExpressibleByBooleanLiteral {
    /// Wraps a boolean literal as `.bool`.
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension AnalyticsValue: ExpressibleByArrayLiteral {
    /// Wraps an array literal as `.array`.
    public init(arrayLiteral elements: AnalyticsValue...) {
        self = .array(elements)
    }
}

extension AnalyticsValue: ExpressibleByDictionaryLiteral {
    /// Wraps a dictionary literal as `.dict`.
    public init(dictionaryLiteral elements: (String, AnalyticsValue)...) {
        self = .dict(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension AnalyticsValue: ExpressibleByNilLiteral {
    /// Wraps a `nil` literal as `.null`.
    public init(nilLiteral: ()) {
        self = .null
    }
}
