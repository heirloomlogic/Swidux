//
//  FeatureFlagsStateTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Swidux
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsState")
struct FeatureFlagsStateTests {
    @Test("default initializer sets empty config and an empty device ID")
    func defaultInit() {
        let state = FeatureFlagsState()
        #expect(state.config == .empty)
        #expect(state.lastFetchedAt == nil)
        #expect(state.localOverrides.isEmpty)
        #expect(state.exposedKeys.isEmpty)
        #expect(state.resolvedDeviceID == "")
        #expect(state.resolvedUserID == nil)
    }

    @Test("hydrated seeds the bucketing device ID from the passed-in value")
    func hydratedSeedsDeviceID() {
        let store = InMemoryKeyValueStore()
        let state = FeatureFlagsState.hydrated(from: store, deviceID: "device-42")
        #expect(state.resolvedDeviceID == "device-42")
        // The seeded device ID is the default bucketing identity until a user signs in.
        #expect(state.defaultBucketingID == "device-42")
    }

    @Test("hydrated recalls last-known config")
    func hydratedRecallsConfig() {
        let store = InMemoryKeyValueStore()
        let config = FeatureFlagsConfig(
            version: 1,
            flags: [
                "x": .boolean(rollout: 50)
            ]
        )
        store.setValue(config, for: .featureFlagsConfig)

        let state = FeatureFlagsState.hydrated(from: store, deviceID: "d")
        #expect(state.config == config)
    }

    @Test("hydrated falls back to defaultConfig when no cache")
    func hydratedUsesDefault() {
        let store = InMemoryKeyValueStore()
        let fallback = FeatureFlagsConfig(version: 1, flags: ["fb": .boolean(rollout: 10)])
        let state = FeatureFlagsState.hydrated(from: store, deviceID: "d", defaultConfig: fallback)
        #expect(state.config == fallback)
    }
}
