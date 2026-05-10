//
//  AnalyticsService.swift
//  SwiduxAnalytics
//

/// Provider-agnostic analytics backend.
///
/// Implementations handle their own batching, retry, network failure,
/// and offline queueing. The plugin invokes these methods fire-and-forget
/// for tracking and identify; only `flush` is awaited.
///
/// ```swift
/// // Mixpanel implementation lives in SwiduxMixpanelAnalytics:
/// struct MixpanelAnalyticsService: AnalyticsService { ... }
/// ```
public protocol AnalyticsService: Sendable {
    /// Record an event.
    func track(_ event: AnalyticsEvent) async

    /// Identify the active user with optional people properties.
    func identify(userID: String, properties: [String: AnalyticsValue]) async

    /// Link an anonymous distinct ID to a known user ID.
    func alias(newID: String, previousID: String?) async

    /// Clear local identity (logout). Subsequent events should be anonymous.
    func reset() async

    /// Drain any in-flight buffers. Awaited by the plugin's `flush()`
    /// during app shutdown.
    func flush() async
}

/// No-op service. Use as a default during development or in previews where
/// no real analytics backend is configured.
public struct MockAnalyticsService: AnalyticsService {
    /// Creates a no-op analytics service.
    public init() {}

    /// No-op.
    public func track(_ event: AnalyticsEvent) async {}
    /// No-op.
    public func identify(userID: String, properties: [String: AnalyticsValue]) async {}
    /// No-op.
    public func alias(newID: String, previousID: String?) async {}
    /// No-op.
    public func reset() async {}
    /// No-op.
    public func flush() async {}
}
