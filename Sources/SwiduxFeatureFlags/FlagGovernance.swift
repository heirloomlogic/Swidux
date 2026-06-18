//
//  FlagGovernance.swift
//  SwiduxFeatureFlags
//
//  Compile-time / test-time governance for feature flags: every flag carries a
//  required owner and expiry, and a single unit test fails — naming the flag and
//  its owner — when any flag outlives its expiry. This keeps "forever flags" out
//  of the codebase. It has no effect on runtime evaluation and never touches the
//  JSON wire format.
//

import Foundation

/// Required governance metadata for one feature flag.
///
/// Build descriptors with the type-erasing factories ``bool(_:owner:expires:purpose:)``,
/// ``variant(_:owner:expires:purpose:)``, and ``value(_:owner:expires:purpose:)`` so the
/// wire key is single-sourced from the typed flag key — no string drift. Because
/// `owner` and `expires` are non-optional factory parameters, a flag can't enter
/// the manifest without them.
///
/// ```swift
/// enum AppFlags {
///     static let newOnboarding = BoolFlag("new_onboarding")
///     static let checkoutLayout = VariantFlag<CheckoutVariant>("checkout_layout", default: .control)
///
///     static let manifest: [FlagDescriptor] = [
///         .bool(newOnboarding, owner: "growth",
///               expires: .init(timeIntervalSince1970: 1_788_000_000), purpose: "New onboarding flow"),
///         .variant(checkoutLayout, owner: "checkout",
///                  expires: .init(timeIntervalSince1970: 1_785_000_000), purpose: "Checkout layout A/B"),
///     ]
/// }
/// ```
///
/// - Note: The manifest is the single declaration site, so a typed flag key that
///   is never added to it escapes governance. Closing that gap fully would need a
///   macro; until then, convention plus code review covers it.
public struct FlagDescriptor: Sendable, Equatable {
    /// Wire-format key, copied from the typed flag key.
    public let key: String
    /// The person or team responsible for retiring this flag.
    public let owner: String
    /// The date on or after which the flag is considered expired.
    public let expires: Date
    /// A short description of what the flag gates — surfaced in the failure report.
    public let purpose: String

    /// Creates a descriptor directly. Prefer the typed factories so the key
    /// stays single-sourced from the flag declaration.
    public init(key: String, owner: String, expires: Date, purpose: String) {
        self.key = key
        self.owner = owner
        self.expires = expires
        self.purpose = purpose
    }
}

extension FlagDescriptor {
    /// Describes a ``BoolFlag``, single-sourcing the key from the typed flag.
    public static func bool(
        _ flag: BoolFlag,
        owner: String,
        expires: Date,
        purpose: String
    ) -> FlagDescriptor {
        FlagDescriptor(key: flag.key, owner: owner, expires: expires, purpose: purpose)
    }

    /// Describes a ``VariantFlag``, single-sourcing the key from the typed flag.
    public static func variant<Variant>(
        _ flag: VariantFlag<Variant>,
        owner: String,
        expires: Date,
        purpose: String
    ) -> FlagDescriptor {
        FlagDescriptor(key: flag.key, owner: owner, expires: expires, purpose: purpose)
    }

    /// Describes a ``ValueFlag``, single-sourcing the key from the typed flag.
    public static func value<Value>(
        _ flag: ValueFlag<Value>,
        owner: String,
        expires: Date,
        purpose: String
    ) -> FlagDescriptor {
        FlagDescriptor(key: flag.key, owner: owner, expires: expires, purpose: purpose)
    }
}

/// Governance checks over a flag manifest.
///
/// Wire one unit test into CI so an expired flag fails the build:
///
/// ```swift
/// @Test func noForeverFlags() {
///     let report = FlagGovernance.expirationReport(AppFlags.manifest)
///     #expect(report == nil, "\(report ?? "")")
/// }
/// ```
public enum FlagGovernance {
    /// Returns the descriptors that have reached or passed their expiry,
    /// oldest-expired first. A flag is expired when `now >= expires`.
    public static func expired(
        in manifest: [FlagDescriptor],
        asOf now: Date = Date()
    ) -> [FlagDescriptor] {
        manifest
            .filter { now >= $0.expires }
            .sorted { $0.expires < $1.expires }
    }

    /// A human-readable report naming every expired flag and its owner, or
    /// `nil` when all flags are still current. Use as the message in a single
    /// CI test so a failure points straight at the flag and its owner.
    public static func expirationReport(
        _ manifest: [FlagDescriptor],
        asOf now: Date = Date()
    ) -> String? {
        let expired = expired(in: manifest, asOf: now)
        guard !expired.isEmpty else { return nil }

        let lines = expired.map { descriptor -> String in
            let days = Int(now.timeIntervalSince(descriptor.expires) / 86_400)
            return "• \(descriptor.key) — owner: \(descriptor.owner) — "
                + "expired \(days)d ago — \(descriptor.purpose)"
        }
        return "Expired feature flags (retire or extend the expiry):\n"
            + lines.joined(separator: "\n")
    }
}
