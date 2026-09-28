//
//  FeatureFlagsReadTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsState read API")
struct FeatureFlagsReadTests {
    enum CheckoutVariant: String { case control, treatment }

    static let fixedDeviceID = "11111111-1111-1111-1111-111111111111"

    func makeState(
        flags: [String: FlagDefinition],
        overrides: [String: FlagValue] = [:]
    ) -> FeatureFlagsState {
        FeatureFlagsState(
            config: FeatureFlagsConfig(version: 1, flags: flags),
            localOverrides: overrides,
            resolvedDeviceID: Self.fixedDeviceID
        )
    }

    // MARK: - Boolean

    @Test("isEnabled returns Swift default when flag missing")
    func boolMissing() {
        let state = makeState(flags: [:])
        #expect(state.isEnabled(BoolFlag("nope"), default: false) == false)
        #expect(state.isEnabled(BoolFlag("nope"), default: true) == true)
    }

    @Test("isEnabled rollout=100 always true")
    func boolFullRollout() {
        let state = makeState(flags: ["f": .boolean(rollout: 100)])
        #expect(state.isEnabled(BoolFlag("f"), default: false) == true)
    }

    @Test("isEnabled rollout=0 always false")
    func boolNoRollout() {
        let state = makeState(flags: ["f": .boolean(rollout: 0)])
        #expect(state.isEnabled(BoolFlag("f"), default: true) == false)
    }

    @Test("local override beats remote rollout")
    func boolOverride() {
        let state = makeState(
            flags: ["f": .boolean(rollout: 0)],
            overrides: ["f": .bool(true)]
        )
        #expect(state.isEnabled(BoolFlag("f"), default: false) == true)
    }

    // MARK: - Variant

    @Test("variant returns Swift default when flag missing")
    func variantMissing() {
        let state = makeState(flags: [:])
        #expect(
            state.variant(of: VariantFlag<CheckoutVariant>("nope", default: .control))
                == .control
        )
    }

    @Test("variant returns Swift default when JSON variant doesn't match enum")
    func variantUnknownString() {
        let state = makeState(flags: [
            "checkout": .variant(variants: [.init(value: "wizard", weight: 100)])
        ])
        #expect(
            state.variant(of: VariantFlag<CheckoutVariant>("checkout", default: .control))
                == .control
        )
    }

    @Test("variant local override beats remote")
    func variantOverride() {
        let state = makeState(
            flags: ["checkout": .variant(variants: [.init(value: "control", weight: 100)])],
            overrides: ["checkout": .string("treatment")]
        )
        #expect(
            state.variant(of: VariantFlag<CheckoutVariant>("checkout", default: .control))
                == .treatment
        )
    }

    // MARK: - Value

    @Test("value returns Swift default when flag missing")
    func valueMissing() {
        let state = makeState(flags: [:])
        #expect(state.value(of: ValueFlag<Int>("max", default: 5)) == 5)
    }

    @Test("value returns config value")
    func valueFromConfig() {
        let state = makeState(flags: ["max": .value(.int(10))])
        #expect(state.value(of: ValueFlag<Int>("max", default: 5)) == 10)
    }

    @Test("value local override beats remote")
    func valueOverride() {
        let state = makeState(
            flags: ["max": .value(.int(10))],
            overrides: ["max": .int(99)]
        )
        #expect(state.value(of: ValueFlag<Int>("max", default: 5)) == 99)
    }

    @Test("a Double flag reads a whole-number remote value, which decodes as Int")
    @MainActor
    func doubleReadsWholeNumber() throws {
        let json = #"{"version":1,"flags":{"ratio":{"type":"value","value":2.0}}}"#
        let config = try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        let state = FeatureFlagsState(config: config, resolvedDeviceID: Self.fixedDeviceID)
        let ratio = ValueFlag<Double>("ratio", default: 1.0)

        #expect(config.flags["ratio"] == .value(.int(2)))
        #expect(state.value(of: ratio) == 2.0)
        #expect(FeatureFlagsState.makeObserver(from: state).value(of: ratio) == 2.0)
    }

    @Test("a Double flag reads an Int local override")
    func doubleReadsIntOverride() {
        let state = makeState(flags: [:], overrides: ["ratio": .int(3)])
        #expect(state.value(of: ValueFlag<Double>("ratio", default: 1.0)) == 3.0)
    }
}
