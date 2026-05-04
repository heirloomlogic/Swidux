//
//  EntitlementSnapshot.swift
//  SwiduxPaywall
//

/// Provider-agnostic snapshot of the user's entitlement status.
public struct EntitlementSnapshot: Sendable, Equatable {
    /// `true` when the user has an active pro subscription.
    public let isPro: Bool
    /// `true` when the user owns a permanent/lifetime license.
    public let hasPermanentLicense: Bool

    /// Creates a snapshot with the given entitlement status.
    public init(isPro: Bool = false, hasPermanentLicense: Bool = false) {
        self.isPro = isPro
        self.hasPermanentLicense = hasPermanentLicense
    }
}
