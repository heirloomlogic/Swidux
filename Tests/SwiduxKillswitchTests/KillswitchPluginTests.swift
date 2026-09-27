//
//  KillswitchPluginTests.swift
//  SwiduxKillswitchTests
//
//  Tests for the KillswitchPlugin reducer.
//

import Foundation
import Swidux
import Synchronization
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
    ) async throws -> [KillswitchAction] {
        guard let effect else { return [] }
        var collected: [KillswitchAction] = []
        try await effect { action in
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
    func fetchUsesCacheWhenFresh() async throws {
        let config = KillswitchConfig(minimumSupportedVersion: "0.5.0")
        try await confirmation("network not called", expectedCount: 0) { networkCall in
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
            let actions = try await collectActions(from: effect)
            #expect(actions.count == 1)
            if case .verdictReceived(.allowed, fromNetwork: false) = actions.first {
            } else {
                Issue.record("Expected cache-served verdictReceived(.allowed), got \(actions)")
            }
        }
    }

    @Test("fetch hits network when cache expired")
    func fetchHitsNetworkWhenCacheExpired() async throws {
        let config = KillswitchConfig()
        try await confirmation("network called") { networkCall in
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
            _ = try await collectActions(from: effect)
        }
    }

    @Test("fetch hits network when lastFetch is in the future (clock skew)")
    func fetchHitsNetworkOnClockSkew() async throws {
        let config = KillswitchConfig()
        try await confirmation("network called") { networkCall in
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
            // A wall clock rolled backward leaves lastFetch in the future;
            // that must count as expired, not pin the install to the cache.
            state.killswitch.lastFetch = Date(timeIntervalSinceNow: 3600)

            let effect = plugin.reduce(
                state: &state, action: .killswitch(.fetch)
            )
            _ = try await collectActions(from: effect)
        }
    }

    @Test("fetch hits network when no prior fetch")
    func fetchHitsNetworkWhenNoPriorFetch() async throws {
        try await confirmation("network called") { networkCall in
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
            _ = try await collectActions(from: effect)
        }
    }

    // MARK: - Force fetch

    @Test("forceFetch bypasses cache")
    func forceFetchBypassesCache() async throws {
        let config = KillswitchConfig()
        try await confirmation("network called") { networkCall in
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
            _ = try await collectActions(from: effect)
        }
    }

    // MARK: - Cache fallback on failure

    @Test("fetch falls back to cache on network error")
    func fetchFallsToCacheOnNetworkError() async throws {
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
        let actions = try await collectActions(from: effect)

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
    func fetchFailsCompletelyWhenNoCacheAndNetworkError() async throws {
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
        let actions = try await collectActions(from: effect)

        #expect(actions.count == 1)
        if case .fetchFailed = actions.first {
        } else {
            Issue.record("Expected fetchFailed, got \(actions)")
        }
    }

    // MARK: - Cold launch

    @Test("a cold-launch fetch shows the cached verdict before the network answers")
    func coldLaunchServesCacheBeforeNetwork() async throws {
        let events = Mutex<[String]>([])
        let service = KillswitchService.mock(
            result: {
                events.withLock { $0.append("network") }
                return KillswitchConfig()
            },
            cached: KillswitchConfig(minimumSupportedVersion: "2.0.0")
        )
        let plugin = makePlugin(service: service)
        var state = TestState()  // cold launch: verdict .unknown, lastFetch nil

        let effect = try #require(plugin.reduce(state: &state, action: .killswitch(.fetch)))
        try await effect { action in
            guard case .killswitch(.verdictReceived(let verdict, let fromNetwork)) = action else { return }
            events.withLock { $0.append("\(verdict.isBlocked ? "blocked" : "allowed") fromNetwork:\(fromNetwork)") }
        }

        // The device already holds a config that blocks this build. Leaving the
        // verdict `.unknown` for the length of the request would let a blocked
        // build run on every launch until the network answers.
        #expect(
            events.withLock { $0 } == [
                "blocked fromNetwork:false",
                "network",
                "allowed fromNetwork:true",
            ])
    }

    @Test("a fetch after a verdict is known does not replay the cache first")
    func warmFetchSkipsCachePreview() async throws {
        let service = KillswitchService.mock(
            result: { KillswitchConfig() },
            cached: KillswitchConfig(minimumSupportedVersion: "2.0.0"),
            cacheLifetime: 60
        )
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.killswitch.verdict = .allowed
        state.killswitch.lastFetch = Date(timeIntervalSinceNow: -120)

        let actions = try await collectActions(
            from: plugin.reduce(state: &state, action: .killswitch(.fetch)))

        #expect(actions.count == 1)
        if case .verdictReceived(.allowed, fromNetwork: true) = actions.first {
        } else {
            Issue.record("Expected only the network verdict, got \(actions)")
        }
    }

    // MARK: - In-flight guard

    @Test("a fetch while another is in flight is dropped until the first finishes")
    func overlappingFetchIsDropped() {
        let plugin = makePlugin()
        var state = TestState()

        let first = plugin.reduce(state: &state, action: .killswitch(.fetch))
        let overlapping = plugin.reduce(state: &state, action: .killswitch(.forceFetch))

        // Two concurrent requests apply in completion order, not issue order —
        // a slow stale response could overwrite a newer verdict and its cache.
        #expect(first != nil)
        #expect(overlapping == nil)

        _ = plugin.reduce(state: &state, action: .killswitch(.verdictReceived(.allowed, fromNetwork: true)))
        #expect(plugin.reduce(state: &state, action: .killswitch(.forceFetch)) != nil)
    }

    @Test("a failed fetch releases the in-flight guard; a cache-served verdict does not")
    func inFlightGuardReleasesOnlyOnCompletion() {
        let plugin = makePlugin()
        var state = TestState()

        _ = plugin.reduce(state: &state, action: .killswitch(.forceFetch))
        // The cold-launch cache preview lands mid-request; it is not the answer.
        _ = plugin.reduce(state: &state, action: .killswitch(.verdictReceived(.allowed, fromNetwork: false)))
        #expect(plugin.reduce(state: &state, action: .killswitch(.fetch)) == nil)

        _ = plugin.reduce(state: &state, action: .killswitch(.fetchFailed("offline")))
        #expect(plugin.reduce(state: &state, action: .killswitch(.fetch)) != nil)
    }

    @Test("a fresh window with no cache on disk re-dispatches as a network fetch")
    func freshWindowWithoutCacheGoesToNetwork() async throws {
        let plugin = makePlugin(service: .mock(cached: nil, cacheLifetime: 3600))
        var state = TestState()
        state.killswitch.lastFetch = Date()

        let actions = try await collectActions(
            from: plugin.reduce(state: &state, action: .killswitch(.fetch)))

        if case .forceFetch = actions.first, actions.count == 1 {
        } else {
            Issue.record("Expected a single .forceFetch, got \(actions)")
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
