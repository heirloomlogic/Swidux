//
//  AnalyticsEvent.swift
//  SwiduxAnalytics
//

/// A single analytics event: a name plus typed properties.
public struct AnalyticsEvent: Sendable, Equatable {
    /// Event name (e.g. `"counter_added"`).
    public var name: String
    /// Event properties keyed by name.
    public var properties: [String: AnalyticsValue]

    /// Creates an event with the given name and optional properties.
    public init(_ name: String, _ properties: [String: AnalyticsValue] = [:]) {
        self.name = name
        self.properties = properties
    }
}
