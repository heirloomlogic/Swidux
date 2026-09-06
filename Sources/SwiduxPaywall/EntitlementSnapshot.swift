//
//  EntitlementSnapshot.swift
//  SwiduxPaywall
//

/// Provider-agnostic snapshot of the user's entitlement status.
public struct EntitlementSnapshot: Sendable, Equatable {
    /// Where a snapshot came from and whether it completes an entitlement read.
    public enum Source: Sendable, Equatable {
        /// A response or update from the live provider.
        case live
        /// A cached fallback completing a one-shot read.
        case cache
        /// A provisional cache value emitted when observation starts. It must
        /// not supersede a live result or complete an in-flight refresh.
        case cacheSeed
    }

    /// `true` when the user has an active pro subscription.
    public let isPro: Bool
    /// `true` when the user owns a permanent/lifetime license.
    public let hasPermanentLicense: Bool
    /// Provenance used by ``PaywallPlugin`` to distinguish provisional cache
    /// seeds from completed reads. Included in snapshot equality.
    public let source: Source

    /// Creates a snapshot with the given entitlement status and provenance.
    /// Providers normally use the default `.live`; cache decorators label
    /// fallback reads `.cache` and provisional stream values `.cacheSeed`.
    public init(isPro: Bool = false, hasPermanentLicense: Bool = false, source: Source = .live) {
        self.isPro = isPro
        self.hasPermanentLicense = hasPermanentLicense
        self.source = source
    }
}
