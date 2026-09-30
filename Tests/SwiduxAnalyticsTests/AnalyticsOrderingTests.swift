import Swidux
import Testing

@testable import SwiduxAnalytics

extension AnalyticsPluginTests {
    @Test("Flush delivers explicit calls in dispatch order")
    func flushIncludesExplicitActions() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .analytics(.identify(userID: "user", properties: [:])))
        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("event"))))
        await plugin.flush()
        #expect(await service.log == ["identify", "track", "flush"])
    }

    @Test("Explicit actions queue their call and return no effect")
    func explicitActionsReturnNoEffect() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        #expect(plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("e")))) == nil)
        #expect(plugin.reduce(state: &state, action: .analytics(.screenView("Home"))) == nil)
        #expect(plugin.reduce(state: &state, action: .analytics(.identify(userID: "u"))) == nil)
        #expect(plugin.reduce(state: &state, action: .analytics(.alias(newID: "u"))) == nil)
        #expect(plugin.reduce(state: &state, action: .analytics(.reset)) == nil)
        #expect(plugin.reduce(state: &state, action: .analytics(.setOptedOut(true))) == nil)
        #expect(plugin.queuedCallCount == 2, "opting out leaves only the explicit reset and its own queued")
        await plugin.flush()
        #expect(await service.log == ["reset", "reset", "flush"])
    }

    @Test("Opt-out discards queued explicit and mapped events, including across opt-in")
    func optOutDiscardsQueuedEvents() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(
            service: service,
            mapper: .init { _, _ in [AnalyticsEvent("mapped")] },
            onConsentChange: { await service.setOptedOut($0) })
        var state = TestState()
        // Submit without yielding so consent changes invalidate both queued paths.
        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("explicit"))))
        plugin.afterReduce(state: &state, action: .unrelated)
        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(true)))
        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(false)))
        await plugin.flush()
        #expect(await service.trackedEvents.isEmpty)
        let log = await service.log
        #expect(log.filter { $0.hasPrefix("consent") } == ["consent(true)", "consent(false)"])
        #expect(log.filter { !$0.hasPrefix("consent") } == ["reset", "flush"])
    }

    @Test("Opting out removes queued calls at once while the service is stalled")
    func optOutFreesQueuedCallsBehindStalledService() async {
        let service = StallingAnalyticsService()
        let plugin = makePlugin(
            service: service,
            mapper: .init { _, _ in [AnalyticsEvent("mapped")] },
            onConsentChange: { await service.setOptedOut($0) })
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("stalled"))))
        await service.trackStarted()

        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("explicit"))))
        _ = plugin.reduce(state: &state, action: .analytics(.screenView("Home")))
        _ = plugin.reduce(state: &state, action: .analytics(.identify(userID: "u1")))
        _ = plugin.reduce(state: &state, action: .analytics(.alias(newID: "u1")))
        plugin.afterReduce(state: &state, action: .unrelated)
        #expect(plugin.queuedCallCount == 5)

        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(true)))
        #expect(plugin.queuedCallCount == 1, "only the reset stays queued")

        await service.release()
        await plugin.flush()
        #expect(await service.log == ["track", "consent(true)", "reset", "flush"])
        #expect(await service.trackedEvents.map(\.name) == ["stalled"])
    }

    @Test("A call queued behind a slow opt-in hook is dropped by a later opt-out")
    func callBehindOptInHookDroppedByLaterOptOut() async {
        let service = RecordingAnalyticsService()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let plugin = makePlugin(
            service: service,
            onConsentChange: { optedOut in
                await service.setOptedOut(optedOut)
                guard !optedOut else { return }
                entered.continuation.yield()
                for await _ in release.stream { break }
            })
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(false)))
        for await _ in entered.stream { break }
        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("gated"))))
        // Give the worker a chance to run; it must leave the call queued while the hook is out.
        try? await poll(until: { plugin.queuedCallCount == 0 }, timeout: .milliseconds(50))
        #expect(plugin.queuedCallCount == 1)
        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(true)))
        release.continuation.yield()
        await plugin.flush()
        #expect(await service.trackedEvents.isEmpty)
        #expect(await service.log == ["consent(false)", "consent(true)", "reset", "flush"])
    }

    @Test("Identity calls survive overflow; the oldest queued track is dropped")
    func identityCallsSurviveOverflow() async {
        let service = StallingAnalyticsService()
        let plugin = makePlugin(service: service, identity: AnalyticsIdentity(userID: \.userID))
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("stalled"))))
        await service.trackStarted()

        let capacity = ServiceCallQueue.droppableCapacity
        state.userID = "u1"
        plugin.afterReduce(state: &state, action: .setUserID("u1"))
        for index in 1...(capacity + 1) {
            _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("\(index)"))))
        }
        _ = plugin.reduce(state: &state, action: .analytics(.alias(newID: "u1")))
        state.userID = nil
        plugin.afterReduce(state: &state, action: .setUserID(nil))
        _ = plugin.reduce(state: &state, action: .analytics(.reset))
        #expect(plugin.queuedCallCount == capacity + 4)

        await service.release()
        await plugin.flush()
        let log = await service.log
        #expect(log.filter { $0 != "track" } == ["identify", "alias", "reset", "reset", "flush"])
        let tracked = await service.trackedEvents.map(\.name)
        #expect(tracked.count == capacity + 1)
        #expect(tracked.prefix(2) == ["stalled", "2"])
        #expect(tracked.last == "\(capacity + 1)")
    }

    @Test("Consent withdrawal bypasses a stalled tracking call")
    func consentBypassesBlockedTracking() async {
        let service = StallingAnalyticsService()
        let plugin = makePlugin(service: service, onConsentChange: { await service.setOptedOut($0) })
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("blocked"))))
        await service.trackStarted()
        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(true)))
        await plugin.flush(timeout: .milliseconds(100))
        #expect(await service.log == ["track", "consent(true)"])
        await service.release()
        await plugin.flush()
        #expect(await service.log == ["track", "consent(true)", "reset", "flush"])
    }

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
