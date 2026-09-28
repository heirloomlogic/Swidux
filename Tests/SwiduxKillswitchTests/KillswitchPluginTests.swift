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

            let staleFetch = try #require(state.killswitch.lastFetch)
            let effect = plugin.reduce(
                state: &state, action: .killswitch(.fetch)
            )
            // Applied in the reducer, not by a later action: nothing can land
            // in between and be overwritten by this older answer.
            #expect(effect == nil)
            #expect(state.killswitch.verdict == .allowed)
            #expect(state.killswitch.lastFetch == staleFetch)
        }
    }

    @Test("a cache read inside the freshness window can't land after a newer network verdict")
    func freshCacheReadCannotOverwriteNewerNetworkVerdict() async throws {
        let service = KillswitchService(
            fetch: { KillswitchConfig(minimumSupportedVersion: "2.0.0") },
            loadCached: { KillswitchConfig() },  // the older config on disk
            saveCached: { _ in },
            cacheLifetime: 3_600
        )
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.killswitch.verdict = .allowed
        state.killswitch.lastFetch = Date()

        // `.fetch` inside the window, then a `.forceFetch` whose network
        // answer lands first.
        let cacheRead = plugin.reduce(state: &state, action: .killswitch(.fetch))
        let network = plugin.reduce(state: &state, action: .killswitch(.forceFetch))
        for action in try await collectActions(from: network) {
            _ = plugin.reduce(state: &state, action: .killswitch(action))
        }
        for action in try await collectActions(from: cacheRead) {
            _ = plugin.reduce(state: &state, action: .killswitch(action))
        }

        #expect(state.killswitch.isBlocked, "the older cached verdict overwrote the newer network one")
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

    // MARK: - Bounded fetch

    /// Observes timeout delivery while the fetch is still suspended. The
    /// iteration budget lets queued actor work run without counting that delay
    /// as fetch execution time; cleanup releases the fetch even on failure.
    private func driveBoundedFetch(honorsCancellation: Bool) async throws {
        let pending = PendingKillswitchFetch(honorsCancellation: honorsCancellation)
        defer { pending.release() }
        let service = KillswitchService(
            fetch: { try await pending.fetch() }, loadCached: { nil }, saveCached: { _ in },
            cacheLifetime: 3_600, fetchTimeout: 0.2)
        let plugin = makePlugin(service: service)
        var state = TestState()
        let effect = try #require(plugin.reduce(state: &state, action: .killswitch(.forceFetch)))
        var dispatched: [TestAction] = []
        var completed = false
        let run = Task { @MainActor in
            try? await effect { dispatched.append($0) }
            completed = true
        }
        for await _ in pending.started { break }
        for _ in 0..<500 {
            if completed && pending.wasCancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let finishedBeforeRelease = completed
        let cancelledBeforeRelease = pending.wasCancelled
        pending.release()
        await run.value

        #expect(finishedBeforeRelease, "fetchTimeout must finish the effect while its fetch is still pending")
        #expect(cancelledBeforeRelease, "the timed-out fetch must be cancelled")
        #expect(dispatched.count == 1)
        if case .killswitch(.fetchFailed(let message)) = dispatched.first {
            #expect(message == URLError(.timedOut).localizedDescription)
        } else {
            Issue.record("Expected fetchFailed with the timeout error, got \(dispatched)")
        }
        for action in dispatched { _ = plugin.reduce(state: &state, action: action) }
        #expect(state.killswitch.isFetching == false)
        #expect(state.killswitch.fetchError == URLError(.timedOut).localizedDescription)
    }

    @Test("a custom fetch that never returns is abandoned at fetchTimeout, releasing the guard")
    func hangingCustomFetchIsBounded() async throws {
        try await driveBoundedFetch(honorsCancellation: true)
    }

    @Test("a fetch that ignores cancellation is still abandoned at fetchTimeout")
    func uncooperativeFetchIsAbandoned() async throws {
        try await driveBoundedFetch(honorsCancellation: false)
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

    @Test("a fresh window with no cache on disk goes to the network, under the guard")
    func freshWindowWithoutCacheGoesToNetwork() async throws {
        let plugin = makePlugin(service: .mock(cached: nil, cacheLifetime: 3600))
        var state = TestState()
        state.killswitch.lastFetch = Date()

        let effect = plugin.reduce(state: &state, action: .killswitch(.fetch))
        #expect(state.killswitch.isFetching)

        let actions = try await collectActions(from: effect)
        if case .verdictReceived(.allowed, fromNetwork: true) = actions.first, actions.count == 1 {
        } else {
            Issue.record("Expected a single network verdict, got \(actions)")
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

/// Models a callback that stays pending until cancellation or explicit cleanup.
private final class PendingKillswitchFetch: Sendable {
    private struct State {
        var continuation: CheckedContinuation<KillswitchConfig, any Error>?
        var cancelled = false
        var released = false
    }
    private let state = Mutex(State())
    private let honorsCancellation: Bool
    private let registration = AsyncStream<Void>.makeStream()
    var started: AsyncStream<Void> { registration.stream }
    var wasCancelled: Bool { state.withLock { $0.cancelled } }

    init(honorsCancellation: Bool) { self.honorsCancellation = honorsCancellation }

    func fetch() async throws -> KillswitchConfig {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<KillswitchConfig, any Error>? = state.withLock { state in
                    if state.cancelled && honorsCancellation { return .failure(CancellationError()) }
                    if state.released { return .success(KillswitchConfig()) }
                    state.continuation = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
                registration.continuation.yield()
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.cancelled = true
                guard self.honorsCancellation else { return nil as CheckedContinuation<KillswitchConfig, any Error>? }
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func release() {
        let continuation = state.withLock { state in
            state.released = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: KillswitchConfig())
    }
}
