//
//  FeatureFlagsDiagnosticsTests.swift
//  SwiduxFeatureFlagsTests
//
//  What the feature-flags plugin logs when a refresh fails.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxFeatureFlags

@Suite("Feature flags diagnostics")
@MainActor
struct FeatureFlagsDiagnosticsTests {
    private typealias TestState = FeatureFlagsPluginTests.TestState
    private typealias TestAction = FeatureFlagsPluginTests.TestAction

    private func makePlugin(
        service: any FeatureFlagsService,
        fetchTimeout: Duration = .seconds(30)
    ) -> FeatureFlagsPlugin<TestState, TestAction> {
        FeatureFlagsPluginTests().makePlugin(service: service, fetchTimeout: fetchTimeout)
    }

    /// Runs one `.refresh` to completion, applying what it dispatches.
    private func refresh(
        _ plugin: FeatureFlagsPlugin<TestState, TestAction>,
        state: inout TestState
    ) async throws {
        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        var dispatched: [TestAction] = []
        try await effect? { dispatched.append($0) }
        for action in dispatched { _ = plugin.reduce(state: &state, action: action) }
    }

    @Test("a failed refresh is logged with the error")
    func failedRefreshIsLogged() async throws {
        let plugin = makePlugin(service: MockFeatureFlagsService(outcome: .failure(URLError(.cannotFindHost))))
        var state = TestState()

        try await refresh(plugin, state: &state)

        let line = try #require(plugin.failureLog.lastLogged)
        #expect(line.contains("URLError \(URLError.Code.cannotFindHost.rawValue)"))
        #expect(state.featureFlags.lastFetchError != nil)
    }

    @Test("a refresh the plugin timed out is logged")
    func timedOutRefreshIsLogged() async throws {
        let plugin = makePlugin(service: HangingFeatureFlagsService(), fetchTimeout: .milliseconds(50))
        var state = TestState()

        try await refresh(plugin, state: &state)

        let line = try #require(plugin.failureLog.lastLogged)
        #expect(line.contains("timed out"))
    }

    @Test("a successful refresh clears the record, so the next failure is logged again")
    func successClearsTheRecord() async throws {
        let service = MockFeatureFlagsService(outcome: .failure(URLError(.timedOut)))
        let plugin = makePlugin(service: service)
        var state = TestState()

        try await refresh(plugin, state: &state)
        #expect(plugin.failureLog.lastLogged != nil)

        service.outcome = .success(.empty)
        try await refresh(plugin, state: &state)
        #expect(plugin.failureLog.lastLogged == nil)

        service.outcome = .failure(URLError(.timedOut))
        try await refresh(plugin, state: &state)
        #expect(plugin.failureLog.lastLogged != nil)
    }

    @Test("a cancelled refresh is not logged")
    func cancelledRefreshIsNotLogged() async throws {
        let plugin = makePlugin(service: MockFeatureFlagsService(outcome: .failure(CancellationError())))
        var state = TestState()

        try await refresh(plugin, state: &state)

        #expect(plugin.failureLog.lastLogged == nil)
        #expect(state.featureFlags.lastFetchError != nil, "state still records the failure")
    }

    @Test("the endpoint is known for the HTTP service and absent for a custom one")
    func endpointComesFromTheHTTPService() {
        let url = URL(static: "https://config.example.test/counter/flags")

        #expect(makePlugin(service: HTTPFeatureFlagsService(url: url)).endpoint == url)
        #expect(makePlugin(service: MockFeatureFlagsService(outcome: .success(.empty))).endpoint == nil)
    }
}
