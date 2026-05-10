//
//  AnalyticsAction.swift
//  SwiduxAnalytics
//

/// Explicit analytics actions for cases the passive mapper can't cover.
///
/// Mapper-driven tracking handles "action happened → emit event"
/// declaratively. These actions cover the gaps: screen views, identity
/// changes the app needs to force, ad-hoc events, and opt-out toggling.
public enum AnalyticsAction: Sendable, Equatable {
    /// Track a one-off event from the app, bypassing the mapper.
    case track(AnalyticsEvent)

    /// Record a screen view. Updates ``AnalyticsState/currentScreen`` and
    /// emits a `"screen_view"` event with `name` plus any extra properties.
    case screenView(String, properties: [String: AnalyticsValue])

    /// Explicitly identify the user (overrides the auto-identify keypath).
    case identify(userID: String, properties: [String: AnalyticsValue])

    /// Link an anonymous distinct ID to a known user — call once when an
    /// anonymous user signs up. `previousID` defaults to the service's
    /// current anonymous ID when `nil`.
    case alias(newID: String, previousID: String?)

    /// Clear local identity (logout). Triggers `service.reset()`.
    case reset

    /// Opt the user in (`false`) or out (`true`) of analytics. Opting out
    /// also clears local identity and calls `service.reset()`.
    case setOptedOut(Bool)
}

extension AnalyticsAction {
    /// Convenience: screen view with no extra properties.
    public static func screenView(_ name: String) -> AnalyticsAction {
        .screenView(name, properties: [:])
    }

    /// Convenience: identify with no extra properties.
    public static func identify(userID: String) -> AnalyticsAction {
        .identify(userID: userID, properties: [:])
    }

    /// Convenience: alias without specifying a previous ID.
    public static func alias(newID: String) -> AnalyticsAction {
        .alias(newID: newID, previousID: nil)
    }
}
