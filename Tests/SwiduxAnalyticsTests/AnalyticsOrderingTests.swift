import Swidux
import Testing

@testable import SwiduxAnalytics

extension AnalyticsPluginTests {
    @Test("Flush includes explicit actions before their effects start")
    func flushIncludesExplicitActions() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .analytics(.identify(userID: "user", properties: [:])))
        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("event"))))
        await plugin.flush()
        #expect(await service.log == ["identify", "track", "flush"])
    }

    @Test("Opt-out discards queued explicit and mapped events, including across opt-in")
    func optOutDiscardsQueuedEvents() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(
            service: service,
            mapper: .init { _, _ in [AnalyticsEvent("mapped")] },
            onConsentChange: { await service.consentChanged(to: $0) })
        var state = TestState()
        // Submit without yielding so consent changes invalidate both queued paths.
        let explicit = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("explicit"))))
        plugin.afterReduce(state: &state, action: .unrelated)
        let optOut = plugin.reduce(state: &state, action: .analytics(.setOptedOut(true)))
        let optIn = plugin.reduce(state: &state, action: .analytics(.setOptedOut(false)))
        try await optIn? { _ in }
        try await optOut? { _ in }
        try await explicit? { _ in }
        await plugin.flush()
        #expect(await service.trackedEvents.isEmpty)
        let log = await service.log
        #expect(log.filter { $0.hasPrefix("consent") } == ["consent(true)", "consent(false)"])
        #expect(log.filter { !$0.hasPrefix("consent") } == ["reset", "flush"])
    }
}

private actor ConsentBlockedService: AnalyticsService {
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    func track(_ event: AnalyticsEvent) async {
        started.continuation.yield()
        for await _ in release.stream { break }
    }
    func identify(userID: String, properties: [String: AnalyticsValue]) async {}
    func alias(newID: String, previousID: String?) async {}
    func reset() async {}
    func flush() async {}
}

extension AnalyticsPluginTests {
    @Test("Consent withdrawal bypasses a blocked tracking call")
    func consentBypassesBlockedTracking() async {
        let service = ConsentBlockedService()
        let consent = RecordingAnalyticsService()
        let plugin = makePlugin(service: service, onConsentChange: { await consent.consentChanged(to: $0) })
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("blocked"))))
        for await _ in service.started.stream { break }
        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(true)))
        await plugin.flush(timeout: .milliseconds(100))
        #expect(await consent.log == ["consent(true)"])
        service.release.continuation.yield()
        await plugin.flush()
    }
}

extension AnalyticsPluginTests {
    @Test("Events following opt-in wait for the SDK consent hook")
    func optInWaitsForConsent() async {
        let service = RecordingAnalyticsService()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let plugin = makePlugin(
            service: service,
            onConsentChange: { _ in
                entered.continuation.yield()
                for await _ in release.stream { break }
            })
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(false)))
        for await _ in entered.stream { break }
        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("after opt-in"))))
        await plugin.flush(timeout: .milliseconds(50))
        #expect(await service.trackedEvents.isEmpty)
        release.continuation.yield()
        await plugin.flush()
        #expect(await service.trackedEvents.map(\.name) == ["after opt-in"])
    }
}
