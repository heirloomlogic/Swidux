//
//  FeatureFlagsConfigTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsConfig")
struct FeatureFlagsConfigTests {
    @Test("decodes complete example with all three flag types")
    func decodesExample() throws {
        let json = """
            {
              "version": 1,
              "flags": {
                "new_onboarding": { "type": "boolean", "rollout": 25 },
                "checkout_layout": {
                  "type": "variant",
                  "variants": [
                    { "value": "control", "weight": 50 },
                    { "value": "treatment", "weight": 50 }
                  ]
                },
                "max_free_uploads": { "type": "value", "value": 5 }
              }
            }
            """
        let config = try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        #expect(config.version == 1)
        #expect(config.flags.count == 3)

        guard case .boolean(let rollout) = config.flags["new_onboarding"] else {
            Issue.record("expected boolean flag")
            return
        }
        #expect(rollout == 25)

        guard case .variant(let variants) = config.flags["checkout_layout"] else {
            Issue.record("expected variant flag")
            return
        }
        #expect(variants.count == 2)
        #expect(variants[0].value == "control")
        #expect(variants[0].weight == 50)

        guard case .value(.int(let n)) = config.flags["max_free_uploads"] else {
            Issue.record("expected value flag")
            return
        }
        #expect(n == 5)
    }

    @Test("decoding fails for unknown version")
    func rejectsUnknownVersion() {
        let json = """
            { "version": 99, "flags": {} }
            """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        }
    }

    @Test("decoding fails for an empty variants array")
    func rejectsEmptyVariants() {
        let json = """
            { "version": 1, "flags": { "k": { "type": "variant", "variants": [] } } }
            """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        }
    }

    @Test("decoding fails for negative variant weights")
    func rejectsNegativeWeights() {
        let json = """
            {
              "version": 1,
              "flags": {
                "k": {
                  "type": "variant",
                  "variants": [
                    { "value": "a", "weight": -5 },
                    { "value": "b", "weight": 105 }
                  ]
                }
              }
            }
            """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        }
    }

    @Test("decoding fails when variant weights do not sum to 100")
    func rejectsWeightsNotSumming() {
        let json = """
            {
              "version": 1,
              "flags": {
                "k": {
                  "type": "variant",
                  "variants": [
                    { "value": "a", "weight": 50 },
                    { "value": "b", "weight": 40 }
                  ]
                }
              }
            }
            """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        }
    }

    @Test("empty config is decodable and has no flags")
    func emptyConfig() throws {
        let json = "{ \"version\": 1, \"flags\": {} }"
        let config = try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        #expect(config.flags.isEmpty)
    }

    @Test(".empty static returns empty config")
    func staticEmpty() {
        #expect(FeatureFlagsConfig.empty.flags.isEmpty)
    }
}
