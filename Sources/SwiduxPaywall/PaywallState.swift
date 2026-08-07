//
//  PaywallState.swift
//  SwiduxPaywall
//

import Foundation
import Swidux

/// Current paywall state — entitlement status, sheet presentation, and async progress.
///
/// Hosted in the app's root state via `@Slice var paywall: PaywallState`.
@Swidux
public nonisolated struct PaywallState: Sendable, Equatable {
    /// `true` when the active entitlement grants pro access.
    public var isPro: Bool = false
    /// `true` when the user owns a permanent license.
    public var hasPermanentLicense: Bool = false
    /// `true` while the paywall sheet is presented.
    public var isPresented: Bool = false
    /// Reason supplied when the paywall was requested.
    public var requestedReason: String? = nil
    /// `true` while an async purchase/restore is in flight.
    public var isLoading: Bool = false
    /// Human-readable error description, or `nil`.
    public var error: String? = nil
    /// `true` while the customer-center sheet is presented.
    public var isCustomerCenterPresented: Bool = false
    /// `true` once `.observeCustomerInfo` has started its long-lived stream.
    /// Guards against double-subscription; maintained by ``PaywallPlugin``.
    public var isObservingCustomerInfo: Bool = false

    /// Creates a paywall state; defaults represent a free, non-presented state.
    public init(
        isPro: Bool = false,
        hasPermanentLicense: Bool = false,
        isPresented: Bool = false,
        requestedReason: String? = nil,
        isLoading: Bool = false,
        error: String? = nil,
        isCustomerCenterPresented: Bool = false,
        isObservingCustomerInfo: Bool = false
    ) {
        self.isPro = isPro
        self.hasPermanentLicense = hasPermanentLicense
        self.isPresented = isPresented
        self.requestedReason = requestedReason
        self.isLoading = isLoading
        self.error = error
        self.isCustomerCenterPresented = isCustomerCenterPresented
        self.isObservingCustomerInfo = isObservingCustomerInfo
    }

    /// `true` when the user is entitled via subscription or permanent license.
    public var isGateSatisfied: Bool { isPro || hasPermanentLicense }
}
