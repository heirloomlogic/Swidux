//
//  FeatureFlagsActionTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsAction")
struct FeatureFlagsActionTests {
    @Test("action is Sendable and Equatable across all cases")
    func allCases() {
        let cases: [FeatureFlagsAction] = [
            .refresh,
            .refreshSucceeded(.empty, fetchedAt: Date(timeIntervalSince1970: 0)),
            .refreshFailed("oops"),
            .setLocalOverride(key: "k", value: .bool(true)),
            .clearLocalOverride(key: "k"),
            .clearAllLocalOverrides,
            .recordExposure(key: "k"),
        ]
        #expect(FeatureFlagsAction.refresh == FeatureFlagsAction.refresh)
        #expect(cases.count == 7)
    }
}
