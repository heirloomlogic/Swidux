import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("Remote config numeric boundaries")
struct ConfigBoundaryTests {
    @Test("Out-of-range rollout is rejected", arguments: [-1, 101, Int.max, Int.min])
    func invalidRollout(_ rollout: Int) {
        let json = """
            {"version":1,"flags":{"x":{"type":"boolean","rollout":\(rollout)}}}
            """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        }
    }

    @Test("Oversized weights throw instead of overflowing")
    func overflowingWeights() {
        let json = """
            {"version":1,"flags":{"x":{"type":"variant","variants":[
            {"value":"a","weight":\(Int.max)},{"value":"b","weight":1}]}}}
            """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        }
    }
}
