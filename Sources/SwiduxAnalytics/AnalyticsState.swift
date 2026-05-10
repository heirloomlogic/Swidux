//
//  AnalyticsState.swift
//  SwiduxAnalytics
//

/// State slice owned by ``AnalyticsPlugin``.
public struct AnalyticsState: Sendable, Equatable {
    /// `true` when the user has opted out of analytics. Mapper events are
    /// dropped, explicit `track`/`identify`/`alias` actions become no-ops,
    /// and auto-identify is paused while opted out.
    public var isOptedOut: Bool

    /// The most recent screen recorded via ``AnalyticsAction/screenView(_:properties:)``,
    /// auto-attached as the `screen` property on subsequent tracked events
    /// (unless the event already carries its own `screen` value).
    public var currentScreen: String?

    /// The userID most recently passed to the analytics service via
    /// `identify` (auto or explicit). Compared against the configured
    /// identity keypath each dispatch to detect transitions.
    public internal(set) var lastIdentifiedUserID: String?

    /// Creates an analytics state slice. `lastIdentifiedUserID` always
    /// starts at `nil`; the plugin manages it from there.
    public init(
        isOptedOut: Bool = false,
        currentScreen: String? = nil
    ) {
        self.isOptedOut = isOptedOut
        self.currentScreen = currentScreen
        self.lastIdentifiedUserID = nil
    }
}
