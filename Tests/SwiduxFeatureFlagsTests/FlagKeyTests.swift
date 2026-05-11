//
//  FlagKeyTests.swift
//  SwiduxFeatureFlagsTests
//

import Testing

@testable import SwiduxFeatureFlags

@Suite("FlagKey")
struct FlagKeyTests {
    enum Variant: String { case control, treatment }

    @Test("BoolFlag exposes its key")
    func boolFlagKey() {
        let flag = BoolFlag("new_onboarding")
        #expect(flag.key == "new_onboarding")
    }

    @Test("VariantFlag exposes its key and default")
    func variantFlagKey() {
        let flag = VariantFlag<Variant>("checkout", default: .control)
        #expect(flag.key == "checkout")
        #expect(flag.defaultValue == .control)
    }

    @Test("ValueFlag exposes its key and default")
    func valueFlagKey() {
        let flag = ValueFlag<Int>("max_uploads", default: 5)
        #expect(flag.key == "max_uploads")
        #expect(flag.defaultValue == 5)
    }
}
