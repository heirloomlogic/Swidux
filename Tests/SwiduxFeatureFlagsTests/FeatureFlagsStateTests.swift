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
    @Test("default initializer sets empty config and generates install ID")
    func defaultInit() {
        let state = FeatureFlagsState()
        #expect(state.config == .empty)
        #expect(state.lastFetchedAt == nil)
        #expect(state.localOverrides.isEmpty)
        #expect(state.exposedKeys.isEmpty)
        #expect(state.installID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    @Test("hydrated reads install ID from key-value store")
    func hydratedRecallsInstallID() {
        let store = InMemoryKeyValueStore()
        let original = UUID()
        store.setValue(original.uuidString, for: .featureFlagsInstallID)

        let state = FeatureFlagsState.hydrated(from: store)
        #expect(state.installID == original)
    }

    @Test("hydrated generates and persists install ID when missing")
    func hydratedGeneratesInstallID() {
        let store = InMemoryKeyValueStore()
        let state = FeatureFlagsState.hydrated(from: store)
        let persisted: String? = store.value(.featureFlagsInstallID)
        #expect(persisted == state.installID.uuidString)
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

        let state = FeatureFlagsState.hydrated(from: store)
        #expect(state.config == config)
    }

    @Test("hydrated falls back to defaultConfig when no cache")
    func hydratedUsesDefault() {
        let store = InMemoryKeyValueStore()
        let fallback = FeatureFlagsConfig(version: 1, flags: ["fb": .boolean(rollout: 10)])
        let state = FeatureFlagsState.hydrated(from: store, defaultConfig: fallback)
        #expect(state.config == fallback)
    }
}
