//
//  AnalyticsIdentity.swift
//  SwiduxAnalytics
//

/// Declarative source-of-truth for the active user's identity.
///
/// When configured on ``AnalyticsPlugin``, both closures are re-evaluated
/// each non-analytics dispatch as pure functions of state. The plugin
/// diffs their return values and fires `service.identify` whenever
/// `userID` or `userProperties` changes, and `service.reset` when
/// `userID` transitions to `nil`. There's no separate "identify on
/// transition" moment — derived people-properties (subscription tier,
/// paywall entitlements, feature flags) stay in sync with state.
///
/// ```swift
/// AnalyticsIdentity(
///     userID: { $0.auth.currentUserID },
///     userProperties: { state in
///         ["subscription_tier": state.paywall.isPro ? "pro" : "free"]
///     }
/// )
/// ```
public struct AnalyticsIdentity<State>: Sendable {
    /// Returns the active user's ID for the current state, or `nil` for anonymous.
    public let userID: @Sendable (State) -> String?

    /// Returns the people-properties to attach when identifying. Re-evaluated
    /// every non-analytics dispatch; `identify` re-fires whenever the
    /// returned dictionary differs from the last value sent.
    public let userProperties: @Sendable (State) -> [String: AnalyticsValue]

    /// Creates an identity source with explicit closures.
    public init(
        userID: @escaping @Sendable (State) -> String?,
        userProperties: @escaping @Sendable (State) -> [String: AnalyticsValue] = { _ in [:] }
    ) {
        self.userID = userID
        self.userProperties = userProperties
    }
}

extension AnalyticsIdentity {
    /// KeyPath convenience: `AnalyticsIdentity(userID: \.auth.currentUserID)`.
    public init(
        userID keyPath: KeyPath<State, String?> & Sendable,
        userProperties: @escaping @Sendable (State) -> [String: AnalyticsValue] = { _ in [:] }
    ) {
        self.init(
            userID: { state in state[keyPath: keyPath] },
            userProperties: userProperties
        )
    }
}
