//
//  PaywallService.swift
//  SwiduxPaywall
//

/// Provider-agnostic paywall service protocol.
///
/// Conform to this protocol with a RevenueCat, StoreKit, or custom implementation.
/// The plugin manages state transitions; the service handles actual purchases.
///
/// ```swift
/// // RevenueCat implementation (in app code, not in Swidux):
/// struct RevenueCatPaywallService: PaywallService { ... }
///
/// // Vanilla StoreKit implementation:
/// struct StoreKitPaywallService: PaywallService { ... }
/// ```
public protocol PaywallService: Sendable {
    func customerInfo() async throws -> EntitlementSnapshot
    func customerInfoStream() -> AsyncStream<EntitlementSnapshot>
    func restorePurchases() async throws -> EntitlementSnapshot
}

/// Test/preview service that returns configurable entitlement snapshots.
public struct MockPaywallService: PaywallService {
    private let snapshot: EntitlementSnapshot

    /// Creates a mock service returning the given entitlement status.
    public init(isPro: Bool = false, hasPermanentLicense: Bool = false) {
        self.snapshot = EntitlementSnapshot(isPro: isPro, hasPermanentLicense: hasPermanentLicense)
    }

    /// Fetches the current entitlement status.
    public func customerInfo() async throws -> EntitlementSnapshot { snapshot }

    /// Long-lived stream of entitlement status updates.
    public func customerInfoStream() -> AsyncStream<EntitlementSnapshot> {
        AsyncStream { $0.finish() }
    }

    /// Restores previously completed purchases.
    public func restorePurchases() async throws -> EntitlementSnapshot { snapshot }
}
