//
//  PaywallAction.swift
//  SwiduxPaywall
//

/// Actions that drive paywall presentation, customer-info observation, and purchases.
public enum PaywallAction: Sendable {
    /// Present the paywall sheet, tagging the request with a feature reason.
    case request(reason: String)
    /// Dismiss the paywall sheet and trigger a customer-info refresh.
    case dismiss
    /// Begin a long-lived subscription to entitlement-status updates from the service.
    case observeCustomerInfo
    /// The entitlement stream finished; clears the guard so observation can be
    /// started again. Dispatched by ``PaywallPlugin``, not by app code.
    case customerInfoStreamEnded
    /// Fetch the current entitlement snapshot once; sets `isLoading`.
    case refreshCustomerInfo
    /// A new entitlement snapshot arrived; updates `isPro` / `hasPermanentLicense`.
    case customerInfoUpdated(EntitlementSnapshot)
    /// A refresh or restore failed; sets `error`.
    case refreshFailed(String)
    /// Restore previously completed purchases via the service.
    case restorePurchases
    /// Present the customer-center sheet.
    case presentCustomerCenter
    /// Dismiss the customer-center sheet.
    case dismissCustomerCenter
    /// Open the system Manage Subscriptions screen.
    case openManageSubscriptions
}
