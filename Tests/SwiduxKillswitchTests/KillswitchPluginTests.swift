//
//  KillswitchPluginTests.swift
//  SwiduxKillswitchTests
//
//  Tests for the KillswitchPlugin reducer.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxKillswitch

@Suite("KillswitchPlugin")
@MainActor
struct KillswitchPluginTests {
    struct TestState: Sendable, Equatable {
        var killswitch = KillswitchState()
    }

    enum TestAction: Sendable {
        case killswitch(KillswitchAction)
        case unrelated
    }

    func makePlugin(
        service: KillswitchService = .mock()
    ) -> KillswitchPlugin<TestState, TestAction> {
        KillswitchPlugin(
            state: \.killswitch,
            action: TestAction.killswitch,
            extractAction: {
                if case .killswitch(let a) = $0 { return a }
                return nil
            },
            service: service,
            appVersion: { "1.0.0" },
            openURL: { _ in }
        )
    }

    private func collectActions(
        from effect: Effect<TestAction>?
    ) async -> [KillswitchAction] {
        guard let effect else { return [] }
        var collected: [KillswitchAction] = []
        await effect { action in
            if case .killswitch(let a) = action {
                collected.append(a)
            }
        }
        return collected
    }

    // MARK: - Routing

    @Test("ignores unrelated actions")
    func ignoresUnrelatedActions() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(state: &state, action: .unrelated)
        #expect(effect == nil)
    }

    // MARK: - Verdict & Error

    @Test("verdictReceived updates state")
    func verdictReceivedUpdatesState() {
        let plugin = makePlugin()
        var state = TestState()
        let verdict = KillswitchVerdict.blocked(
            title: "Blocked",
            message: "Update now",
            updateURL: nil
        )
        let effect = plugin.reduce(
            state: &state,
            action: .killswitch(.verdictReceived(verdict, fromNetwork: true))
        )
        #expect(effect == nil)
        #expect(state.killswitch.verdict == verdict)
        #expect(state.killswitch.lastFetch != nil)
        #expect(state.killswitch.fetchError == nil)
    }

    @Test("cache-served verdict does not refresh the freshness window")
    func cacheServedVerdictKeepsFreshnessWindow() {
        let plugin = makePlugin()
        var state = TestState()
        let staleFetch = Date(timeIntervalSinceNow: -120)
        state.killswitch.lastFetch = staleFetch

        _ = plugin.reduce(
            state: &state,
            action: .killswitch(.verdictReceived(.allowed, fromNetwork: false))
        )

        // The verdict lands, but `lastFetch` keeps its old value — otherwise a
        // session polling .fetch inside cacheLifetime would never hit the
        // network again and a newly published block/unblock would not be seen.
        #expect(state.killswitch.verdict == .allowed)
        #expect(state.killswitch.lastFetch == staleFetch)
    }

    @Test("fetchFailed records error")
    func fetchFailedRecordsError() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .killswitch(.fetchFailed("Network error"))
        )
        #expect(effect == nil)
        #expect(state.killswitch.fetchError == "Network error")
    }

    // MARK: - Cache-first fetch

    @Test("fetch uses cache when fresh")
    func fetchUsesCacheWhenFresh() async {
        let config = KillswitchConfig(minimumSupportedVersion: "0.5.0")
        await confirmation("network not called", expectedCount: 0) { networkCall in
            let service = KillswitchService.mock(
                result: {
                    networkCall()
                    return KillswitchConfig()
                },
                cached: config,
                cacheLifetime: 3600
            )
            let plugin = makePlugin(service: service)
            var state = TestState()
            state.killswitch.lastFetch = Date()

            let effect = plugin.reduce(
                state: &state, action: .killswitch(.fetch)
            )
            let actions = await collectActions(from: effect)
            #expect(actions.count == 1)
            if case .verdictReceived(.allowed, fromNetwork: false) = actions.first {
            } else {
                Issue.record("Expected cache-served verdictReceived(.allowed), got \(actions)")
            }
        }
    }

    @Test("fetch hits network when cache expired")
    func fetchHitsNetworkWhenCacheExpired() async {
        let config = KillswitchConfig()
        await confirmation("network called") { networkCall in
            let service = KillswitchService.mock(
                result: {
                    networkCall()
                    return config
                },
                cached: config,
                cacheLifetime: 60
            )
            let plugin = makePlugin(service: service)
            var state = TestState()
            state.killswitch.lastFetch = Date(timeIntervalSinceNow: -120)

            let effect = plugin.reduce(
                state: &state, action: .killswitch(.fetch)
            )
            _ = await collectActions(from: effect)
        }
    }

    @Test("fetch hits network when no prior fetch")
    func fetchHitsNetworkWhenNoPriorFetch() async {
        await confirmation("network called") { networkCall in
            let service = KillswitchService.mock(
                result: {
                    networkCall()
                    return KillswitchConfig()
                },
                cacheLifetime: 3600
            )
            let plugin = makePlugin(service: service)
            var state = TestState()

            let effect = plugin.reduce(
                state: &state, action: .killswitch(.fetch)
            )
            _ = await collectActions(from: effect)
        }
    }

    // MARK: - Force fetch

    @Test("forceFetch bypasses cache")
    func forceFetchBypassesCache() async {
        let config = KillswitchConfig()
        await confirmation("network called") { networkCall in
            let service = KillswitchService.mock(
                result: {
                    networkCall()
                    return config
                },
                cached: config,
                cacheLifetime: 3600
            )
            let plugin = makePlugin(service: service)
            var state = TestState()
            state.killswitch.lastFetch = Date()

            let effect = plugin.reduce(
                state: &state, action: .killswitch(.forceFetch)
            )
            _ = await collectActions(from: effect)
        }
    }

    // MARK: - Cache fallback on failure

    @Test("fetch falls back to cache on network error")
    func fetchFallsToCacheOnNetworkError() async {
        let cached = KillswitchConfig(minimumSupportedVersion: "2.0.0")
        let service = KillswitchService.mock(
            result: { throw URLError(.notConnectedToInternet) },
            cached: cached,
            cacheLifetime: 3600
        )
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(
            state: &state, action: .killswitch(.fetch)
        )
        let actions = await collectActions(from: effect)

        #expect(actions.count == 2)
        if case .verdictReceived(.blocked, fromNetwork: false) = actions.first {
        } else {
            Issue.record("Expected cache-served verdictReceived(.blocked), got \(actions)")
        }
        if case .fetchFailed = actions.last {
        } else {
            Issue.record("Expected fetchFailed, got \(actions)")
        }
    }

    @Test("fetch dispatches only fetchFailed when no cache and network error")
    func fetchFailsCompletelyWhenNoCacheAndNetworkError() async {
        let service = KillswitchService.mock(
            result: { throw URLError(.notConnectedToInternet) },
            cached: nil,
            cacheLifetime: 3600
        )
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(
            state: &state, action: .killswitch(.fetch)
        )
        let actions = await collectActions(from: effect)

        #expect(actions.count == 1)
        if case .fetchFailed = actions.first {
        } else {
            Issue.record("Expected fetchFailed, got \(actions)")
        }
    }

    // MARK: - Computed properties

    @Test(
        "isBlocked",
        arguments: [
            (KillswitchVerdict.unknown, false),
            (.allowed, false),
            (.blocked(title: nil, message: nil, updateURL: nil), true),
        ]
    )
    func isBlocked(verdict: KillswitchVerdict, expected: Bool) {
        let state = KillswitchState(verdict: verdict)
        #expect(state.isBlocked == expected)
    }

    @Test(
        "canOpenUpdateURL",
        arguments: [
            (KillswitchVerdict.unknown, false),
            (.allowed, false),
            (.blocked(title: nil, message: nil, updateURL: nil), false),
            (
                .blocked(
                    title: nil, message: nil,
                    updateURL: URL(static: "https://example.com")
                ), true
            ),
            (
                .blocked(
                    title: nil, message: nil,
                    updateURL: URL(static: "itms-apps://apps.apple.com/app/id123")
                ), true
            ),
            // Remote config must not be able to open arbitrary schemes.
            (
                .blocked(
                    title: nil, message: nil,
                    updateURL: URL(static: "file:///etc/passwd")
                ), false
            ),
        ]
    )
    func canOpenUpdateURL(verdict: KillswitchVerdict, expected: Bool) {
        let state = KillswitchState(verdict: verdict)
        #expect(state.canOpenUpdateURL == expected)
    }
}
