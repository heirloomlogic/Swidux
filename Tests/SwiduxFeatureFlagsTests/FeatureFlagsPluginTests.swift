//
//  FeatureFlagsPluginTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Swidux
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsPlugin")
@MainActor
struct FeatureFlagsPluginTests {
    // MARK: - Test fixtures

    struct TestState: Sendable, Equatable {
        var featureFlags = FeatureFlagsState()
        var userID: String? = nil
    }

    enum TestAction: Sendable, Equatable {
        case featureFlags(FeatureFlagsAction)
        case unrelated
    }

    func makePlugin(
        service: any FeatureFlagsService = MockFeatureFlagsService(outcome: .success(.empty)),
        userIDKeyPath: KeyPath<TestState, String?>? = nil,
        refreshPolicy: RefreshPolicy = .manual,
        defaultConfig: FeatureFlagsConfig? = nil,
        keyValueStore: any KeyValueStore = InMemoryKeyValueStore(),
        onExposure: (@Sendable (String, FlagValue) -> Void)? = nil
    ) -> FeatureFlagsPlugin<TestState, TestAction> {
        FeatureFlagsPlugin(
            state: \.featureFlags,
            action: TestAction.featureFlags,
            extractAction: {
                if case .featureFlags(let a) = $0 { return a }
                return nil
            },
            service: service,
            userIDKeyPath: userIDKeyPath,
            refreshPolicy: refreshPolicy,
            defaultConfig: defaultConfig,
            keyValueStore: keyValueStore,
            onExposure: onExposure
        )
    }

    // MARK: - .refresh

    @Test(".refresh hits the service and dispatches refreshSucceeded")
    func refreshSuccess() async {
        let config = FeatureFlagsConfig(version: 1, flags: ["f": .boolean(rollout: 50)])
        let service = MockFeatureFlagsService(outcome: .success(config))
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        #expect(state.featureFlags.isFetching)

        var dispatched: [TestAction] = []
        await effect?({ action in dispatched.append(action) })

        #expect(service.fetchCount == 1)
        #expect(dispatched.count == 1)
        guard case .featureFlags(.refreshSucceeded(let received, _)) = dispatched[0] else {
            Issue.record("expected refreshSucceeded")
            return
        }
        #expect(received == config)
    }

    @Test(".refresh dispatches refreshFailed on service error")
    func refreshFailure() async {
        let service = MockFeatureFlagsService(outcome: .failure(URLError(.notConnectedToInternet)))
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        var dispatched: [TestAction] = []
        await effect?({ action in dispatched.append(action) })

        #expect(dispatched.count == 1)
        guard case .featureFlags(.refreshFailed) = dispatched[0] else {
            Issue.record("expected refreshFailed")
            return
        }
    }

    @Test(".refreshSucceeded updates state with new config and clears isFetching")
    func refreshSucceededUpdatesState() {
        let plugin = makePlugin()
        var state = TestState()
        state.featureFlags.isFetching = true
        let config = FeatureFlagsConfig(version: 1, flags: ["x": .boolean(rollout: 100)])
        let now = Date()

        _ = plugin.reduce(
            state: &state,
            action: .featureFlags(.refreshSucceeded(config, fetchedAt: now))
        )

        #expect(state.featureFlags.config == config)
        #expect(state.featureFlags.lastFetchedAt == now)
        #expect(state.featureFlags.isFetching == false)
        #expect(state.featureFlags.lastFetchError == nil)
    }

    @Test(".refreshFailed records error message and clears isFetching")
    func refreshFailedUpdatesState() {
        let plugin = makePlugin()
        var state = TestState()
        state.featureFlags.isFetching = true

        _ = plugin.reduce(state: &state, action: .featureFlags(.refreshFailed("boom")))

        #expect(state.featureFlags.isFetching == false)
        #expect(state.featureFlags.lastFetchError == "boom")
    }

    @Test("automatic policy debounces refresh inside minInterval")
    func automaticDebounce() async {
        let service = MockFeatureFlagsService(outcome: .success(.empty))
        let plugin = makePlugin(service: service, refreshPolicy: .automatic(minInterval: 300))
        var state = TestState()
        state.featureFlags.lastFetchedAt = Date()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        await effect?({ _ in })

        #expect(service.fetchCount == 0)
    }

    @Test("manual policy never debounces")
    func manualNeverDebounces() async {
        let service = MockFeatureFlagsService(outcome: .success(.empty))
        let plugin = makePlugin(service: service, refreshPolicy: .manual)
        var state = TestState()
        state.featureFlags.lastFetchedAt = Date()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        await effect?({ _ in })

        #expect(service.fetchCount == 1)
    }
}
