//
//  AnalyticsIdentity.swift
//  SwiduxAnalytics
//

/// Declarative source-of-truth for the active user's identity.
///
/// When configured on ``AnalyticsPlugin``, the plugin watches the userID
/// closure across dispatches and fires `service.identify` / `service.reset`
/// on transitions, with `userProperties` snapshotted at identify time.
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

    /// Returns the people-properties snapshot to attach when identifying.
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
