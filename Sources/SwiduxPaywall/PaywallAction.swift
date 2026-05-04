//
//  PaywallAction.swift
//  SwiduxPaywall
//

/// Actions that drive paywall presentation, customer-info observation, and purchases.
public enum PaywallAction: Sendable {
    case request(reason: String)
    case dismiss
    case observeCustomerInfo
    case refreshCustomerInfo
    case customerInfoUpdated(EntitlementSnapshot)
    case refreshFailed(String)
    case restorePurchases
    case presentCustomerCenter
    case dismissCustomerCenter
    case openManageSubscriptions
}
