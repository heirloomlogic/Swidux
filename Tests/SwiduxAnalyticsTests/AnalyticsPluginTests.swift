//
//  AnalyticsPluginTests.swift
//  SwiduxAnalyticsTests
//

import Foundation
import Swidux
import Testing

@testable import SwiduxAnalytics

@Suite("AnalyticsPlugin")
@MainActor
struct AnalyticsPluginTests {
    // MARK: - Test fixtures

    struct TestState: Sendable, Equatable {
        var analytics = AnalyticsState()
        var counter: Int = 0
        var userID: String? = nil
    }

    enum TestAction: Sendable, Equatable {
        case analytics(AnalyticsAction)
        case incrementBy(Int)
        case setUserID(String?)
        case unrelated
    }

    func makePlugin(
        service: any AnalyticsService = MockAnalyticsService(),
        mapper: AnalyticsMapper<TestState, TestAction> = .none,
        identity: AnalyticsIdentity<TestState>? = nil,
        onConsentChange: (@Sendable (Bool) async -> Void)? = nil
    ) -> AnalyticsPlugin<TestState, TestAction> {
        AnalyticsPlugin(
            state: \.analytics,
            action: TestAction.analytics,
            extractAction: {
                if case .analytics(let a) = $0 { return a }
                return nil
            },
            service: service,
            mapper: mapper,
            identity: identity,
            onConsentChange: onConsentChange
        )
    }

    // MARK: - Mapper-driven tracking

    @Test("mapper returning empty array makes no service calls")
    func mapperEmpty() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service, mapper: .none)
        var state = TestState()

        plugin.afterReduce(state: &state, action: .incrementBy(1))
        await plugin.flush()

        let events = await service.trackedEvents
        #expect(events.isEmpty)
    }

    @Test("mapper returning one event calls service.track once")
    func mapperOneEvent() async throws {
        let service = RecordingAnalyticsService()
        let mapper = AnalyticsMapper<TestState, TestAction> { _, action in
            if case .incrementBy(let n) = action {
                return [AnalyticsEvent("counter_added", ["amount": .int(n)])]
            }
            return []
        }
        let plugin = makePlugin(service: service, mapper: mapper)
        var state = TestState()

        plugin.afterReduce(state: &state, action: .incrementBy(5))
        await plugin.flush()

        let events = await service.trackedEvents
        #expect(events.count == 1)
        #expect(events.first?.name == "counter_added")
        #expect(events.first?.properties["amount"] == .int(5))
    }

    @Test("mapper returning multiple events calls service.track in order")
    func mapperMultipleEvents() async throws {
        let service = RecordingAnalyticsService()
        let mapper = AnalyticsMapper<TestState, TestAction> { _, _ in
            [
                AnalyticsEvent("first"),
                AnalyticsEvent("second"),
                AnalyticsEvent("third"),
            ]
        }
        let plugin = makePlugin(service: service, mapper: mapper)
        var state = TestState()

        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let events = await service.trackedEvents
        #expect(events.map(\.name) == ["first", "second", "third"])
    }

    @Test("currentScreen is auto-attached to mapper events")
    func currentScreenAutoAttach() async throws {
        let service = RecordingAnalyticsService()
        let mapper = AnalyticsMapper<TestState, TestAction> { _, _ in
            [AnalyticsEvent("button_tap")]
        }
        let plugin = makePlugin(service: service, mapper: mapper)
        var state = TestState()
        state.analytics.currentScreen = "Settings"

        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let events = await service.trackedEvents
        #expect(events.first?.properties["screen"] == .string("Settings"))
    }

    @Test("app-provided screen wins over auto-attach")
    func appProvidedScreenWins() async throws {
        let service = RecordingAnalyticsService()
        let mapper = AnalyticsMapper<TestState, TestAction> { _, _ in
            [AnalyticsEvent("button_tap", ["screen": .string("Override")])]
        }
        let plugin = makePlugin(service: service, mapper: mapper)
        var state = TestState()
        state.analytics.currentScreen = "Settings"

        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let events = await service.trackedEvents
        #expect(events.first?.properties["screen"] == .string("Override"))
    }

    @Test("mapper is skipped when isOptedOut")
    func mapperSkippedWhenOptedOut() async throws {
        let service = RecordingAnalyticsService()
        let mapper = AnalyticsMapper<TestState, TestAction> { _, _ in
            [AnalyticsEvent("should_not_fire")]
        }
        let plugin = makePlugin(service: service, mapper: mapper)
        var state = TestState()
        state.analytics.isOptedOut = true

        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let events = await service.trackedEvents
        #expect(events.isEmpty)
    }

    @Test("mapper is skipped for analytics actions (no double-tracking)")
    func mapperSkippedForAnalyticsActions() async throws {
        let service = RecordingAnalyticsService()
        let mapper = AnalyticsMapper<TestState, TestAction> { _, _ in
            [AnalyticsEvent("from_mapper")]
        }
        let plugin = makePlugin(service: service, mapper: mapper)
        var state = TestState()

        // afterReduce alone (the explicit track is handled by reduce, but we're
        // testing afterReduce's short-circuit on analytics actions here).
        plugin.afterReduce(
            state: &state,
            action: .analytics(.track(AnalyticsEvent("from_explicit")))
        )
        await plugin.flush()

        // No mapper events fire, and the explicit .track event isn't doubled
        // because reduce wasn't invoked in this test path.
        let events = await service.trackedEvents
        #expect(events.isEmpty)
    }

    // MARK: - Explicit AnalyticsAction: track

    @Test(".track calls service with enriched event")
    func trackCallsService() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.currentScreen = "Home"

        let event = AnalyticsEvent("custom", ["foo": .string("bar")])
        _ = plugin.reduce(state: &state, action: .analytics(.track(event)))
        await plugin.flush()

        let events = await service.trackedEvents
        #expect(events.count == 1)
        #expect(events.first?.name == "custom")
        #expect(events.first?.properties["foo"] == .string("bar"))
        #expect(events.first?.properties["screen"] == .string("Home"))
    }

    @Test(".track is skipped when opted out")
    func trackSkippedWhenOptedOut() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.isOptedOut = true

        _ = plugin.reduce(
            state: &state,
            action: .analytics(.track(AnalyticsEvent("nope")))
        )
        await plugin.flush()

        let events = await service.trackedEvents
        #expect(events.isEmpty)
    }

    // MARK: - Explicit AnalyticsAction: screenView

    @Test(".screenView updates currentScreen and tracks screen_view")
    func screenViewUpdatesAndTracks() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()

        _ = plugin.reduce(
            state: &state,
            action: .analytics(.screenView("Profile", properties: ["origin": .string("tab")]))
        )
        await plugin.flush()

        #expect(state.analytics.currentScreen == "Profile")
        let events = await service.trackedEvents
        #expect(events.count == 1)
        #expect(events.first?.name == "screen_view")
        #expect(events.first?.properties["screen_name"] == .string("Profile"))
        #expect(events.first?.properties["origin"] == .string("tab"))
    }

    @Test(".screenView updates currentScreen even when opted out")
    func screenViewUpdatesStateWhenOptedOut() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.isOptedOut = true

        _ = plugin.reduce(
            state: &state,
            action: .analytics(.screenView("Profile"))
        )

        #expect(state.analytics.currentScreen == "Profile")
        #expect(plugin.queuedCallCount == 0)
        let events = await service.trackedEvents
        #expect(events.isEmpty)
    }

    // MARK: - Explicit AnalyticsAction: identify, alias, reset

    @Test(".identify updates lastIdentifiedUserID and calls service.identify")
    func identifyUpdatesAndCalls() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()

        _ = plugin.reduce(
            state: &state,
            action: .analytics(
                .identify(userID: "u1", properties: ["plan": .string("pro")])
            )
        )
        await plugin.flush()

        #expect(state.analytics.lastIdentifiedUserID == "u1")
        let calls = await service.identifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.userID == "u1")
        #expect(calls.first?.properties["plan"] == .string("pro"))
    }

    @Test(".alias calls service.alias without state mutation")
    func aliasCallsService() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        let before = state

        _ = plugin.reduce(
            state: &state,
            action: .analytics(.alias(newID: "user-42", previousID: "anon-7"))
        )
        await plugin.flush()

        #expect(state == before)
        let calls = await service.aliasCalls
        #expect(calls.count == 1)
        #expect(calls.first?.newID == "user-42")
        #expect(calls.first?.previousID == "anon-7")
    }

    @Test(".reset clears lastIdentifiedUserID/Properties and calls service.reset")
    func resetClearsAndCalls() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.lastIdentifiedUserID = "u1"
        state.analytics.lastIdentifiedProperties = ["tier": .string("pro")]

        _ = plugin.reduce(state: &state, action: .analytics(.reset))
        await plugin.flush()

        #expect(state.analytics.lastIdentifiedUserID == nil)
        #expect(state.analytics.lastIdentifiedProperties == [:])
        let resets = await service.resetCount
        #expect(resets == 1)
    }

    @Test("explicit .identify and .alias are skipped when opted out")
    func explicitSkippedWhenOptedOut() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.isOptedOut = true

        _ = plugin.reduce(state: &state, action: .analytics(.identify(userID: "u1")))
        _ = plugin.reduce(state: &state, action: .analytics(.alias(newID: "n")))
        await plugin.flush()

        let identifyCalls = await service.identifyCalls
        let aliasCalls = await service.aliasCalls
        #expect(identifyCalls.isEmpty)
        #expect(aliasCalls.isEmpty)
    }

    @Test("an opted-out .identify does not poison identification after opting back in")
    func optedOutIdentifyDoesNotPoisonLaterIdentify() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.isOptedOut = true

        // Suppressed — and must not be recorded as "already identified".
        _ = plugin.reduce(state: &state, action: .analytics(.identify(userID: "u1")))
        #expect(state.analytics.lastIdentifiedUserID == nil)

        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(false)))

        // The same identify after opting back in must reach the service.
        _ = plugin.reduce(state: &state, action: .analytics(.identify(userID: "u1")))
        await plugin.flush()
        let identifyCalls = await service.identifyCalls
        #expect(identifyCalls.count == 1)
        #expect(state.analytics.lastIdentifiedUserID == "u1")
    }

    // MARK: - Explicit AnalyticsAction: setOptedOut

    @Test(".setOptedOut(true) sets flag, clears identity, calls service.reset")
    func optOutClearsAndResets() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.lastIdentifiedUserID = "u1"

        _ = plugin.reduce(
            state: &state,
            action: .analytics(.setOptedOut(true))
        )
        await plugin.flush()

        #expect(state.analytics.isOptedOut == true)
        #expect(state.analytics.lastIdentifiedUserID == nil)
        let resets = await service.resetCount
        #expect(resets == 1)
    }

    @Test(".setOptedOut(false) clears flag without service call")
    func optInClearsFlagOnly() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.isOptedOut = true

        _ = plugin.reduce(
            state: &state,
            action: .analytics(.setOptedOut(false))
        )

        #expect(state.analytics.isOptedOut == false)
        #expect(plugin.queuedCallCount == 0)
        let resets = await service.resetCount
        #expect(resets == 0)
    }

    // MARK: - Explicit AnalyticsAction: consent hook

    @Test("opt-out invokes the consent hook before service.reset")
    func optOutRunsConsentHookBeforeReset() async throws {
        let recorder = RecordingAnalyticsService()
        let plugin = makePlugin(
            service: recorder,
            onConsentChange: { optedOut in await recorder.setOptedOut(optedOut) }
        )
        var state = TestState()

        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(true)))
        await plugin.flush()

        // Order matters: the SDK's own opt-out must close the tap before the
        // reset hands it an identity change that is still eligible to be sent.
        let log = await recorder.log
        #expect(log == ["consent(true)", "reset", "flush"])
    }

    @Test("opt-in invokes the consent hook without resetting")
    func optInRunsConsentHookOnly() async throws {
        let recorder = RecordingAnalyticsService()
        let plugin = makePlugin(
            service: recorder,
            onConsentChange: { optedOut in await recorder.setOptedOut(optedOut) }
        )
        var state = TestState()
        state.analytics.isOptedOut = true

        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(false)))
        await plugin.flush()

        #expect(state.analytics.isOptedOut == false)
        let log = await recorder.log
        #expect(log == ["consent(false)", "flush"])
    }

    @Test("consent hook is optional — opt-in queues nothing without one")
    func consentHookDefaultsToNil() async throws {
        let recorder = RecordingAnalyticsService()
        let plugin = makePlugin(service: recorder)
        var state = TestState()
        state.analytics.isOptedOut = true

        _ = plugin.reduce(
            state: &state,
            action: .analytics(.setOptedOut(false))
        )

        #expect(plugin.queuedCallCount == 0)
        await plugin.flush()
        let log = await recorder.log
        #expect(log == ["flush"])
    }

    @Test("consent hook does not reopen the plugin-side gate")
    func consentHookDoesNotUngateDispatch() async throws {
        let recorder = RecordingAnalyticsService()
        let plugin = makePlugin(
            service: recorder,
            onConsentChange: { optedOut in await recorder.setOptedOut(optedOut) }
        )
        var state = TestState()

        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(true)))
        // Every dispatch path must still short-circuit while opted out.
        _ = plugin.reduce(state: &state, action: .analytics(.track(AnalyticsEvent("e"))))
        _ = plugin.reduce(state: &state, action: .analytics(.screenView("home")))
        _ = plugin.reduce(state: &state, action: .analytics(.identify(userID: "u1", properties: [:])))
        _ = plugin.reduce(state: &state, action: .analytics(.alias(newID: "n", previousID: nil)))
        await plugin.flush()

        let log = await recorder.log
        #expect(log == ["consent(true)", "reset", "flush"])
    }

    // MARK: - Auto-identify

    @Test("auto-identify fires on nil → userID transition")
    func autoIdentifyOnSignIn() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(
            userID: { $0.userID },
            userProperties: { _ in ["tier": .string("free")] }
        )
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.userID = "u1"

        plugin.afterReduce(state: &state, action: .setUserID("u1"))
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.userID == "u1")
        #expect(calls.first?.properties["tier"] == .string("free"))
        #expect(state.analytics.lastIdentifiedUserID == "u1")
        #expect(state.analytics.lastIdentifiedProperties == ["tier": .string("free")])
    }

    @Test("auto-identify fires on userID change")
    func autoIdentifyOnUserIDChange() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(userID: { $0.userID })
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.analytics.lastIdentifiedUserID = "u1"
        state.userID = "u2"

        plugin.afterReduce(state: &state, action: .setUserID("u2"))
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.userID == "u2")
        #expect(state.analytics.lastIdentifiedUserID == "u2")
    }

    @Test("auto-identify calls service.reset on userID → nil transition")
    func autoIdentifyOnSignOut() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(userID: { $0.userID })
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.analytics.lastIdentifiedUserID = "u1"
        state.analytics.lastIdentifiedProperties = ["tier": .string("pro")]
        state.userID = nil

        plugin.afterReduce(state: &state, action: .setUserID(nil))
        await plugin.flush()

        let resets = await service.resetCount
        #expect(resets == 1)
        let identifyCalls = await service.identifyCalls
        #expect(identifyCalls.isEmpty)
        #expect(state.analytics.lastIdentifiedUserID == nil)
        #expect(state.analytics.lastIdentifiedProperties == [:])
    }

    @Test("auto-identify is a no-op when userID is unchanged")
    func autoIdentifyStable() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(userID: { $0.userID })
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.analytics.lastIdentifiedUserID = "u1"
        state.userID = "u1"

        plugin.afterReduce(state: &state, action: .unrelated)
        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let calls = await service.identifyCalls
        let resets = await service.resetCount
        #expect(calls.isEmpty)
        #expect(resets == 0)
    }

    @Test("auto-identify userProperties closure receives current state")
    func autoIdentifyPropertiesFromState() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(
            userID: { $0.userID },
            userProperties: { state in
                ["counter_value": .int(state.counter)]
            }
        )
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.userID = "u1"
        state.counter = 42

        plugin.afterReduce(state: &state, action: .setUserID("u1"))
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.first?.properties["counter_value"] == .int(42))
    }

    @Test("auto-identify is paused when opted out")
    func autoIdentifyPausedWhenOptedOut() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(userID: { $0.userID })
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.analytics.isOptedOut = true
        state.userID = "u1"

        plugin.afterReduce(state: &state, action: .setUserID("u1"))
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.isEmpty)
        // Crucially, lastIdentifiedUserID stays nil so opt-in re-identifies.
        #expect(state.analytics.lastIdentifiedUserID == nil)
    }

    @Test("opting back in re-identifies on next dispatch")
    func optInReIdentifies() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(userID: { $0.userID })
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.userID = "u1"
        state.analytics.isOptedOut = true

        // While opted out: no identify, no state update.
        plugin.afterReduce(state: &state, action: .setUserID("u1"))
        await plugin.flush()

        // Opt back in via the explicit path (skips afterReduce processing).
        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(false)))
        await plugin.flush()

        // Next non-analytics dispatch should fire identify("u1").
        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.userID == "u1")
        #expect(state.analytics.lastIdentifiedUserID == "u1")
    }

    @Test("auto-identify re-fires when userProperties content changes with stable userID")
    func autoIdentifyOnPropertiesChange() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(
            userID: { $0.userID },
            userProperties: { state in ["counter": .int(state.counter)] }
        )
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.userID = "u1"
        state.counter = 1

        plugin.afterReduce(state: &state, action: .setUserID("u1"))
        state.counter = 2
        plugin.afterReduce(state: &state, action: .incrementBy(1))
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.count == 2)
        #expect(calls.first?.properties["counter"] == .int(1))
        #expect(calls.last?.properties["counter"] == .int(2))
        #expect(state.analytics.lastIdentifiedProperties == ["counter": .int(2)])
    }

    @Test("auto-identify preserves submission order across rapid afterReduce calls")
    func autoIdentifyPreservesOrderUnderRapidCalls() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(
            userID: { $0.userID },
            userProperties: { state in ["counter": .int(state.counter)] }
        )
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.userID = "u1"

        for index in 1...100 {
            state.counter = index
            plugin.afterReduce(state: &state, action: .incrementBy(1))
        }
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.count == 100)
        let counters: [Int] = calls.compactMap { call in
            if case .int(let n) = call.properties["counter"] { return n }
            return nil
        }
        #expect(counters == Array(1...100))
    }

    @Test("auto-identify is a no-op when both userID and userProperties are stable")
    func autoIdentifyStableProperties() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(
            userID: { $0.userID },
            userProperties: { _ in ["tier": .string("free")] }
        )
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.userID = "u1"

        plugin.afterReduce(state: &state, action: .setUserID("u1"))
        plugin.afterReduce(state: &state, action: .unrelated)
        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.count == 1)
    }

    @Test("property changes do not fire identify while opted out")
    func autoIdentifyPropertiesChangeWhileOptedOut() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(
            userID: { $0.userID },
            userProperties: { state in ["counter": .int(state.counter)] }
        )
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.analytics.isOptedOut = true
        state.userID = "u1"
        state.counter = 1

        plugin.afterReduce(state: &state, action: .setUserID("u1"))
        state.counter = 2
        plugin.afterReduce(state: &state, action: .incrementBy(1))
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.isEmpty)
        #expect(state.analytics.lastIdentifiedProperties == [:])
    }

    @Test("explicit .identify records properties so auto-identify sees no diff")
    func explicitIdentifyRecordsPropertiesForAutoPath() async throws {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(
            userID: { $0.userID },
            userProperties: { _ in ["plan": .string("pro")] }
        )
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.userID = "u1"

        _ = plugin.reduce(
            state: &state,
            action: .analytics(.identify(userID: "u1", properties: ["plan": .string("pro")]))
        )
        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.properties["plan"] == .string("pro"))
        #expect(state.analytics.lastIdentifiedProperties == ["plan": .string("pro")])
    }

    // MARK: - Explicit identify vs auto-identify

    /// The documented use of `.identify`: force identity before the auth state
    /// the identity keypath reads has landed.
    private func identifyAheadOfState(
        _ service: RecordingAnalyticsService
    ) -> (AnalyticsPlugin<TestState, TestAction>, TestState) {
        let plugin = makePlugin(service: service, identity: AnalyticsIdentity(userID: \.userID))
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .analytics(.identify(userID: "u1")))
        return (plugin, state)
    }

    @Test("explicit .identify survives dispatches before state catches up")
    func explicitIdentifyAheadOfStateIsNotReset() async throws {
        let service = RecordingAnalyticsService()
        let (plugin, initial) = identifyAheadOfState(service)
        var state = initial

        plugin.afterReduce(state: &state, action: .unrelated)
        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let log = await service.log
        #expect(log == ["identify", "flush"])
        #expect(state.analytics.lastIdentifiedUserID == "u1")
    }

    @Test("state catching up to the explicit ID does not re-identify")
    func stateCatchingUpToExplicitIdentify() async throws {
        let service = RecordingAnalyticsService()
        let (plugin, initial) = identifyAheadOfState(service)
        var state = initial
        plugin.afterReduce(state: &state, action: .unrelated)

        state.userID = "u1"
        plugin.afterReduce(state: &state, action: .setUserID("u1"))
        await plugin.flush()

        let log = await service.log
        #expect(log == ["identify", "flush"])
    }

    @Test("once state has caught up, its later transitions drive identity again")
    func stateTransitionsAfterExplicitIdentify() async throws {
        let service = RecordingAnalyticsService()
        let (plugin, initial) = identifyAheadOfState(service)
        var state = initial
        state.userID = "u1"
        plugin.afterReduce(state: &state, action: .setUserID("u1"))

        state.userID = "u2"
        plugin.afterReduce(state: &state, action: .setUserID("u2"))
        state.userID = nil
        plugin.afterReduce(state: &state, action: .setUserID(nil))
        await plugin.flush()

        let log = await service.log
        let identified = await service.identifyCalls.map(\.userID)
        #expect(log == ["identify", "identify", "reset", "flush"])
        #expect(identified == ["u1", "u2"])
        #expect(state.analytics.lastIdentifiedUserID == nil)
    }

    @Test("state moving off its value at .identify time takes over, sign-out included")
    func stateSignOutAfterExplicitOverride() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service, identity: AnalyticsIdentity(userID: \.userID))
        var state = TestState()
        state.userID = "u2"
        plugin.afterReduce(state: &state, action: .setUserID("u2"))

        // Override what state says; the override holds while state is unchanged.
        _ = plugin.reduce(state: &state, action: .analytics(.identify(userID: "u1")))
        plugin.afterReduce(state: &state, action: .unrelated)
        state.userID = nil
        plugin.afterReduce(state: &state, action: .setUserID(nil))
        await plugin.flush()

        let log = await service.log
        let identified = await service.identifyCalls.map(\.userID)
        #expect(log == ["identify", "identify", "reset", "flush"])
        #expect(identified == ["u2", "u1"])
    }

    @Test("opting out drops an explicit identity, so opting back in re-identifies from state")
    func optOutDropsExplicitIdentity() async throws {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service, identity: AnalyticsIdentity(userID: \.userID))
        var state = TestState()
        state.userID = "u2"
        plugin.afterReduce(state: &state, action: .setUserID("u2"))
        _ = plugin.reduce(state: &state, action: .analytics(.identify(userID: "u1")))
        // Deliver the explicit identify first: opting out discards queued calls.
        await plugin.flush()

        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(true)))
        _ = plugin.reduce(state: &state, action: .analytics(.setOptedOut(false)))
        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let identified = await service.identifyCalls.map(\.userID)
        #expect(identified == ["u2", "u1", "u2"])
        #expect(state.analytics.lastIdentifiedUserID == "u2")
    }

    // MARK: - Flush

    @Test("flush awaits pending tasks and calls service.flush")
    func flushDrainsAndFlushes() async throws {
        let service = RecordingAnalyticsService()
        let mapper = AnalyticsMapper<TestState, TestAction> { _, _ in
            [AnalyticsEvent("e")]
        }
        let plugin = makePlugin(service: service, mapper: mapper)
        var state = TestState()

        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let events = await service.trackedEvents
        let flushes = await service.flushCount
        #expect(events.count == 1)
        #expect(flushes == 1)
    }

    @Test("flush(timeout:) returns even when the service flush hangs")
    func flushTimeoutBoundsHungService() async throws {
        let service = HangingAnalyticsService()
        let plugin = makePlugin(service: service)

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await plugin.flush(timeout: .milliseconds(50))
        }

        #expect(elapsed < .seconds(5), "a hung service.flush() must not block past the timeout")
    }

    @Test("flush(timeout:) gives up on hung in-flight work")
    func flushTimeoutBoundsHungInflightWork() async throws {
        let service = HangingAnalyticsService()  // track() also hangs
        let mapper = AnalyticsMapper<TestState, TestAction> { _, _ in
            [AnalyticsEvent("e")]
        }
        let plugin = makePlugin(service: service, mapper: mapper)
        var state = TestState()

        plugin.afterReduce(state: &state, action: .unrelated)  // spawns a hung track
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await plugin.flush(timeout: .milliseconds(50))
        }

        #expect(elapsed < .seconds(5), "hung in-flight work must not block past the timeout")
    }

    @Test("concurrent flushes both complete")
    func concurrentFlushesBothComplete() async throws {
        let service = RecordingAnalyticsService()
        let mapper = AnalyticsMapper<TestState, TestAction> { _, _ in
            [AnalyticsEvent("e")]
        }
        let plugin = makePlugin(service: service, mapper: mapper)
        var state = TestState()
        plugin.afterReduce(state: &state, action: .unrelated)

        async let first: Void = plugin.flush()
        async let second: Void = plugin.flush(timeout: .seconds(10))
        _ = await (first, second)

        let flushes = await service.flushCount
        #expect(flushes == 2)
    }

    // MARK: - Lifting (root ↔ analytics action plumbing)

    @Test("reduce returns nil for non-analytics actions")
    func reduceIgnoresUnrelated() {
        let plugin = makePlugin()
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .unrelated)
        #expect(plugin.queuedCallCount == 0)
        #expect(state == TestState())
    }

    // MARK: - AnalyticsValue literal conformances

    @Test("AnalyticsValue literals produce the expected cases")
    func valueLiterals() {
        let dict: [String: AnalyticsValue] = [
            "amount": 5,
            "tier": "pro",
            "active": true,
            "ratio": 0.5,
            "tags": ["a", "b"],
        ]
        #expect(dict["amount"] == .int(5))
        #expect(dict["tier"] == .string("pro"))
        #expect(dict["active"] == .bool(true))
        #expect(dict["ratio"] == .double(0.5))
        #expect(dict["tags"] == .array([.string("a"), .string("b")]))

        let nilValue: AnalyticsValue = nil
        #expect(nilValue == .null)
    }
}

// `RecordingAnalyticsService` is shared — see RecordingAnalyticsService.swift.
