//
//  FeatureFlagsActionTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsAction")
struct FeatureFlagsActionTests {
    enum Layout: String { case control, treatment }
    enum OtherLayout: String { case control, treatment }

    @Test("action is Sendable and Equatable across all cases")
    func allCases() {
        let cases: [FeatureFlagsAction] = [
            .refresh,
            .refreshSucceeded(.empty, fetchedAt: Date(timeIntervalSince1970: 0)),
            .refreshFailed("oops"),
            .setLocalOverride(key: "k", value: .bool(true)),
            .clearLocalOverride(key: "k"),
            .clearAllLocalOverrides,
            .recordExposure(of: BoolFlag("k")),
        ]
        #expect(FeatureFlagsAction.refresh == FeatureFlagsAction.refresh)
        #expect(cases.count == 7)
    }

    @Test("exposures are equal exactly when they name the same key, flag type, and bucketing ID")
    func exposureEquality() {
        let layout = VariantFlag<Layout>("layout", default: .control)
        #expect(FeatureFlagsAction.recordExposure(of: layout) == .recordExposure(of: layout))
        #expect(
            FeatureFlagsAction.recordExposure(of: layout)
                != .recordExposure(of: VariantFlag<OtherLayout>("layout", default: .control))
        )
        #expect(
            FeatureFlagsAction.recordExposure(of: layout)
                != .recordExposure(of: layout, bucketingID: "team-1")
        )
        #expect(
            FeatureFlagsAction.recordExposure(of: BoolFlag("layout"))
                != .recordExposure(of: VariantFlag<Layout>("other", default: .control))
        )
    }
}
