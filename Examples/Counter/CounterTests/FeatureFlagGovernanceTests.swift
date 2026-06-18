import Foundation
import SwiduxFeatureFlags
import Testing

@testable import Counter

@MainActor
@Suite("Feature flag governance")
struct FeatureFlagGovernanceTests {
    /// Fails — naming each flag and its owner — when any feature flag has
    /// outlived its expiry. Retire the flag (delete it and its code paths) or,
    /// if it genuinely needs more time, bump the expiry in `FlagManifest`.
    @Test("no feature flag has outlived its expiry")
    func noForeverFlags() {
        let report = FlagGovernance.expirationReport(FlagManifest.all)
        #expect(report == nil, "\(report ?? "")")
    }
}
