//
//  PaywallState.swift
//  SwiduxPaywall
//

/// Current paywall state — entitlement status, sheet presentation, and async progress.
public struct PaywallState: Sendable, Equatable {
    /// `true` when the active entitlement grants pro access.
    public var isPro: Bool
    /// `true` when the user owns a permanent license.
    public var hasPermanentLicense: Bool
    /// `true` while the paywall sheet is presented.
    public var isPresented: Bool
    /// Reason supplied when the paywall was requested.
    public var requestedReason: String?
    /// `true` while an async purchase/restore is in flight.
    public var isLoading: Bool
    /// Human-readable error description, or `nil`.
    public var error: String?
    /// `true` while the customer-center sheet is presented.
    public var isCustomerCenterPresented: Bool

    /// Creates a paywall state; defaults represent a free, non-presented state.
    public init(
        isPro: Bool = false,
        hasPermanentLicense: Bool = false,
        isPresented: Bool = false,
        requestedReason: String? = nil,
        isLoading: Bool = false,
        error: String? = nil,
        isCustomerCenterPresented: Bool = false
    ) {
        self.isPro = isPro
        self.hasPermanentLicense = hasPermanentLicense
        self.isPresented = isPresented
        self.requestedReason = requestedReason
        self.isLoading = isLoading
        self.error = error
        self.isCustomerCenterPresented = isCustomerCenterPresented
    }

    /// `true` when the user is entitled via subscription or permanent license.
    public var isGateSatisfied: Bool { isPro || hasPermanentLicense }
}
