//
//  ConsoleAnalyticsService.swift
//  SwiduxAnalytics
//

import Foundation
import os

/// Analytics service that logs every call to the unified logging system
/// (`os.Logger`) instead of sending to a provider.
///
/// Use this as the default `service:` while the analytics vendor decision is
/// still open. Unlike the silent ``MockAnalyticsService`` (which is for
/// previews and tests), `ConsoleAnalyticsService` behaves like a micro version
/// of the real thing: every `track`, `identify`, `alias`, `reset`, and `flush`
/// is printed to the Xcode console and Console.app, so analytics wiring can be
/// developed and QA-tested end to end with no SDK and no vendor commitment.
///
/// Swapping in a real provider later is the usual two-line change in
/// `Store.configured()` — nothing else in the app changes.
public struct ConsoleAnalyticsService: AnalyticsService {
    private let logger: Logger

    /// Creates a console-logging analytics service.
    ///
    /// - Parameters:
    ///   - subsystem: OSLog subsystem. Defaults to `"Swidux"`.
    ///   - category: OSLog category. Defaults to `"Analytics"`.
    public init(subsystem: String = "Swidux", category: String = "Analytics") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    /// Logs the event name and its properties.
    public func track(_ event: AnalyticsEvent) async {
        logger.info(
            "track \(event.name, privacy: .public) \(consoleAnalyticsPropertiesDescription(event.properties), privacy: .public)"
        )
    }

    /// Logs the identified user ID and people properties.
    public func identify(userID: String, properties: [String: AnalyticsValue]) async {
        logger.info(
            "identify \(userID, privacy: .public) \(consoleAnalyticsPropertiesDescription(properties), privacy: .public)"
        )
    }

    /// Logs the alias link.
    public func alias(newID: String, previousID: String?) async {
        logger.info(
            "alias \(newID, privacy: .public) <- \(previousID ?? "nil", privacy: .public)"
        )
    }

    /// Logs the identity reset.
    public func reset() async {
        logger.info("reset")
    }

    /// Logs the flush marker.
    public func flush() async {
        logger.info("flush")
    }
}

/// Renders a single ``AnalyticsValue`` as a human-readable string for console
/// output. Dictionary keys are sorted so output is deterministic.
func consoleAnalyticsDescription(_ value: AnalyticsValue) -> String {
    switch value {
    case .string(let string):
        return string
    case .int(let int):
        return String(int)
    case .double(let double):
        return String(double)
    case .bool(let bool):
        return bool ? "true" : "false"
    case .date(let date):
        return date.ISO8601Format()
    case .null:
        return "null"
    case .array(let elements):
        return "[" + elements.map(consoleAnalyticsDescription).joined(separator: ", ") + "]"
    case .dict(let dict):
        let body = dict.sorted { $0.key < $1.key }
            .map { "\($0.key): \(consoleAnalyticsDescription($0.value))" }
            .joined(separator: ", ")
        return "{" + body + "}"
    }
}

/// Renders an analytics property bag as a sorted, comma-separated string.
/// Returns `"{}"` for an empty bag.
func consoleAnalyticsPropertiesDescription(_ properties: [String: AnalyticsValue]) -> String {
    guard !properties.isEmpty else { return "{}" }
    return properties.sorted { $0.key < $1.key }
        .map { "\($0.key)=\(consoleAnalyticsDescription($0.value))" }
        .joined(separator: ", ")
}
