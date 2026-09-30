//
//  KillswitchDiagnosticsTests.swift
//  SwiduxKillswitchTests
//
//  What the killswitch reports when its remote config fails or looks wrong.
//

import Foundation
import Swidux
import Synchronization
import Testing

@testable import SwiduxKillswitch

@Suite("Killswitch diagnostics")
@MainActor
struct KillswitchDiagnosticsTests {
    private typealias TestState = KillswitchPluginTests.TestState
    private typealias TestAction = KillswitchPluginTests.TestAction

    private let endpoint = URL(static: "https://config.example.test/counter/killswitch")

    private func makePlugin(service: KillswitchService) -> KillswitchPlugin<TestState, TestAction> {
        KillswitchPluginTests().makePlugin(service: service)
    }

    /// Runs one `.forceFetch` to completion, applying what it dispatches.
    private func forceFetch(
        _ plugin: KillswitchPlugin<TestState, TestAction>,
        state: inout TestState
    ) async throws {
        let effect = plugin.reduce(state: &state, action: .killswitch(.forceFetch))
        var dispatched: [TestAction] = []
        try await effect? { dispatched.append($0) }
        for action in dispatched { _ = plugin.reduce(state: &state, action: action) }
    }

    private func service(
        throwing error: (any Error)? = nil,
        cached: KillswitchConfig? = nil
    ) -> KillswitchService {
        var service = KillswitchService.mock(
            result: {
                if let error { throw error }
                return KillswitchConfig()
            },
            cached: cached
        )
        service.endpoint = endpoint
        return service
    }

    // MARK: - Fetch failures

    @Test("a failed fetch is logged with the endpoint and the error")
    func failedFetchIsLogged() async throws {
        let plugin = makePlugin(service: service(throwing: URLError(.cannotFindHost)))
        var state = TestState()

        try await forceFetch(plugin, state: &state)

        let line = try #require(plugin.failureLog.lastLogged)
        #expect(line.contains(endpoint.absoluteString))
        #expect(line.contains("URLError \(URLError.Code.cannotFindHost.rawValue)"))
        #expect(state.killswitch.fetchError != nil)
    }

    @Test("a failure that falls back to the cache is still logged, and the verdict is unchanged")
    func cacheFallbackIsStillLogged() async throws {
        let blocking = KillswitchConfig(minimumSupportedVersion: "2.0.0")
        let plugin = makePlugin(service: service(throwing: URLError(.timedOut), cached: blocking))
        var state = TestState()
        state.killswitch.verdict = .allowed

        try await forceFetch(plugin, state: &state)

        #expect(plugin.failureLog.lastLogged != nil)
        #expect(state.killswitch.isBlocked)
    }

    @Test("a successful fetch clears the record, so the next failure is logged again")
    func successClearsTheRecord() async throws {
        let outage = Outage()
        var service = KillswitchService.mock(result: {
            if outage.isOn { throw URLError(.timedOut) }
            return KillswitchConfig()
        })
        service.endpoint = endpoint
        let plugin = makePlugin(service: service)
        var state = TestState()

        try await forceFetch(plugin, state: &state)
        #expect(plugin.failureLog.lastLogged != nil)

        outage.isOn = false
        try await forceFetch(plugin, state: &state)
        #expect(plugin.failureLog.lastLogged == nil)

        outage.isOn = true
        try await forceFetch(plugin, state: &state)
        #expect(plugin.failureLog.lastLogged != nil)
    }

    @Test("a cancelled fetch is not logged")
    func cancelledFetchIsNotLogged() async throws {
        let plugin = makePlugin(service: service(throwing: CancellationError()))
        var state = TestState()

        try await forceFetch(plugin, state: &state)

        #expect(plugin.failureLog.lastLogged == nil)
        #expect(state.killswitch.fetchError != nil, "state still records the failure")
    }

    @Test("the live service knows its endpoint; a hand-built one doesn't")
    func liveServiceCarriesItsEndpoint() {
        #expect(KillswitchService.live(endpoint: endpoint).endpoint == endpoint)
        #expect(KillswitchService.mock().endpoint == nil)
    }

    // MARK: - Unknown keys

    @Test("a misspelled key is reported as unknown")
    func misspelledKeyIsUnknown() {
        let json = #"{"minimumSupportedVerison": "1.5.0", "blockedTitle": "Update"}"#

        #expect(KillswitchConfig.unknownKeys(in: Data(json.utf8)) == ["minimumSupportedVerison"])
    }

    @Test("every key the config declares is known")
    func declaredKeysAreKnown() throws {
        let full = KillswitchConfig(
            minimumSupportedVersion: "1.0.0", blockedVersions: ["1.0.1"],
            blockedRanges: ["1.1.0..<1.2.0"], blockedTitle: "t", blockedMessage: "m",
            updateURL: "https://example.test"
        )
        let data = try JSONEncoder().encode(full)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object.count == 6)
        #expect(KillswitchConfig.unknownKeys(in: data).isEmpty)
    }

    @Test("a body that isn't a JSON object reports nothing")
    func nonObjectReportsNothing() {
        #expect(KillswitchConfig.unknownKeys(in: Data("[1, 2]".utf8)).isEmpty)
        #expect(KillswitchConfig.unknownKeys(in: Data("not json".utf8)).isEmpty)
    }

    @Test("unknown keys are sorted, so the report is stable")
    func unknownKeysAreSorted() {
        let json = #"{"zeta": 1, "alpha": 2, "blockedVersions": []}"#

        #expect(KillswitchConfig.unknownKeys(in: Data(json.utf8)) == ["alpha", "zeta"])
    }
}

/// A switch a fetch closure can read while the test flips it.
private final class Outage: Sendable {
    private let on = Mutex(true)

    var isOn: Bool {
        get { on.withLock { $0 } }
        set { on.withLock { $0 = newValue } }
    }
}
