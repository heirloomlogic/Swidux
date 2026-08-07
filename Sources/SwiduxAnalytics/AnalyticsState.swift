//
//  AnalyticsState.swift
//  SwiduxAnalytics
//

import Foundation
import Swidux

/// State slice owned by ``AnalyticsPlugin``.
///
/// Hosted in the app's root state via `@Slice var analytics: AnalyticsState`.
@Swidux
public nonisolated struct AnalyticsState: Sendable, Equatable {
    /// `true` when the user has opted out of analytics. Mapper events are
    /// dropped, explicit `track`/`identify`/`alias` actions become no-ops,
    /// and auto-identify is paused while opted out.
    public var isOptedOut: Bool = false

    /// The most recent screen recorded via ``AnalyticsAction/screenView(_:properties:)``,
    /// auto-attached as the `screen` property on subsequent tracked events
    /// (unless the event already carries its own `screen` value).
    public var currentScreen: String? = nil

    /// The userID most recently passed to the analytics service via
    /// `identify` (auto or explicit). Compared against the configured
    /// identity keypath each dispatch to detect transitions.
    ///
    /// `internal(set)` guards the reducer path only — the generated observer
    /// mirrors every stored property as a settable `var`. See <doc:MacrosReference>.
    public internal(set) var lastIdentifiedUserID: String? = nil

    /// The properties most recently passed to `service.identify` (auto or
    /// explicit). Compared against the configured identity's `userProperties`
    /// each dispatch to detect content changes that should re-fire identify.
    public internal(set) var lastIdentifiedProperties: [String: AnalyticsValue] = [:]

    /// Creates an analytics state slice. `lastIdentified*` fields always
    /// start empty; the plugin manages them from there.
    public init(
        isOptedOut: Bool = false,
        currentScreen: String? = nil
    ) {
        self.isOptedOut = isOptedOut
        self.currentScreen = currentScreen
        self.lastIdentifiedUserID = nil
        self.lastIdentifiedProperties = [:]
    }
}

extension AnalyticsState {
    mutating func recordIdentified(userID: String, properties: [String: AnalyticsValue]) {
        lastIdentifiedUserID = userID
        lastIdentifiedProperties = properties
    }

    mutating func clearIdentified() {
        lastIdentifiedUserID = nil
        lastIdentifiedProperties = [:]
    }
}
