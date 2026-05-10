//
//  AnalyticsMapper.swift
//  SwiduxAnalytics
//

/// Declarative mapping from `(state, action)` pairs to analytics events.
///
/// Configured once at plugin registration and run by ``AnalyticsPlugin``
/// in `afterReduce` for every non-analytics action while the user is
/// opted in. Returning an empty array is the no-op case.
///
/// ```swift
/// AnalyticsMapper { state, action in
///     switch action {
///     case .counter(.add(let n)):
///         return [AnalyticsEvent("counter_added", ["amount": .int(n)])]
///     case .paywall(.request(let reason)):
///         return [AnalyticsEvent("paywall_requested", ["reason": .string(reason)])]
///     default:
///         return []
///     }
/// }
/// ```
public struct AnalyticsMapper<State, Action>: Sendable {
    /// Closure that produces zero or more events for a given `(state, action)` pair.
    public typealias Map = @Sendable (State, Action) -> [AnalyticsEvent]

    /// The configured mapping closure.
    public let map: Map

    /// Creates a mapper from an explicit closure.
    public init(_ map: @escaping Map) {
        self.map = map
    }

    /// A mapper that emits no events. Default for plugins that only use
    /// explicit `AnalyticsAction` dispatches.
    public static var none: AnalyticsMapper {
        AnalyticsMapper { _, _ in [] }
    }
}
