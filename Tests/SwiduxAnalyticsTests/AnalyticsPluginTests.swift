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
        identity: AnalyticsIdentity<TestState>? = nil
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
            identity: identity
        )
    }

    private func runEffect(_ effect: Effect<TestAction>?) async {
        guard let effect else { return }
        await effect { _ in }
    }

    // MARK: - Mapper-driven tracking

    @Test("mapper returning empty array makes no service calls")
    func mapperEmpty() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service, mapper: .none)
        var state = TestState()

        plugin.afterReduce(state: &state, action: .incrementBy(1))
        await plugin.flush()

        let events = await service.trackedEvents
        #expect(events.isEmpty)
    }

    @Test("mapper returning one event calls service.track once")
    func mapperOneEvent() async {
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
    func mapperMultipleEvents() async {
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
    func currentScreenAutoAttach() async {
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
    func appProvidedScreenWins() async {
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
    func mapperSkippedWhenOptedOut() async {
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
    func mapperSkippedForAnalyticsActions() async {
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
    func trackCallsService() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.currentScreen = "Home"

        let event = AnalyticsEvent("custom", ["foo": .string("bar")])
        let effect = plugin.reduce(state: &state, action: .analytics(.track(event)))
        await runEffect(effect)

        let events = await service.trackedEvents
        #expect(events.count == 1)
        #expect(events.first?.name == "custom")
        #expect(events.first?.properties["foo"] == .string("bar"))
        #expect(events.first?.properties["screen"] == .string("Home"))
    }

    @Test(".track is skipped when opted out")
    func trackSkippedWhenOptedOut() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.isOptedOut = true

        let effect = plugin.reduce(
            state: &state,
            action: .analytics(.track(AnalyticsEvent("nope")))
        )
        await runEffect(effect)

        let events = await service.trackedEvents
        #expect(events.isEmpty)
        #expect(effect == nil)
    }

    // MARK: - Explicit AnalyticsAction: screenView

    @Test(".screenView updates currentScreen and tracks screen_view")
    func screenViewUpdatesAndTracks() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(
            state: &state,
            action: .analytics(.screenView("Profile", properties: ["origin": .string("tab")]))
        )
        await runEffect(effect)

        #expect(state.analytics.currentScreen == "Profile")
        let events = await service.trackedEvents
        #expect(events.count == 1)
        #expect(events.first?.name == "screen_view")
        #expect(events.first?.properties["screen_name"] == .string("Profile"))
        #expect(events.first?.properties["origin"] == .string("tab"))
    }

    @Test(".screenView updates currentScreen even when opted out")
    func screenViewUpdatesStateWhenOptedOut() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.isOptedOut = true

        let effect = plugin.reduce(
            state: &state,
            action: .analytics(.screenView("Profile"))
        )

        #expect(state.analytics.currentScreen == "Profile")
        #expect(effect == nil)
        let events = await service.trackedEvents
        #expect(events.isEmpty)
    }

    // MARK: - Explicit AnalyticsAction: identify, alias, reset

    @Test(".identify updates lastIdentifiedUserID and calls service.identify")
    func identifyUpdatesAndCalls() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(
            state: &state,
            action: .analytics(
                .identify(userID: "u1", properties: ["plan": .string("pro")])
            )
        )
        await runEffect(effect)

        #expect(state.analytics.lastIdentifiedUserID == "u1")
        let calls = await service.identifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.userID == "u1")
        #expect(calls.first?.properties["plan"] == .string("pro"))
    }

    @Test(".alias calls service.alias without state mutation")
    func aliasCallsService() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        let before = state

        let effect = plugin.reduce(
            state: &state,
            action: .analytics(.alias(newID: "user-42", previousID: "anon-7"))
        )
        await runEffect(effect)

        #expect(state == before)
        let calls = await service.aliasCalls
        #expect(calls.count == 1)
        #expect(calls.first?.newID == "user-42")
        #expect(calls.first?.previousID == "anon-7")
    }

    @Test(".reset clears lastIdentifiedUserID/Properties and calls service.reset")
    func resetClearsAndCalls() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.lastIdentifiedUserID = "u1"
        state.analytics.lastIdentifiedProperties = ["tier": .string("pro")]

        let effect = plugin.reduce(state: &state, action: .analytics(.reset))
        await runEffect(effect)

        #expect(state.analytics.lastIdentifiedUserID == nil)
        #expect(state.analytics.lastIdentifiedProperties == [:])
        let resets = await service.resetCount
        #expect(resets == 1)
    }

    @Test("explicit .identify and .alias are skipped when opted out")
    func explicitSkippedWhenOptedOut() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.isOptedOut = true

        await runEffect(
            plugin.reduce(state: &state, action: .analytics(.identify(userID: "u1")))
        )
        await runEffect(
            plugin.reduce(state: &state, action: .analytics(.alias(newID: "n")))
        )

        let identifyCalls = await service.identifyCalls
        let aliasCalls = await service.aliasCalls
        #expect(identifyCalls.isEmpty)
        #expect(aliasCalls.isEmpty)
    }

    // MARK: - Explicit AnalyticsAction: setOptedOut

    @Test(".setOptedOut(true) sets flag, clears identity, calls service.reset")
    func optOutClearsAndResets() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.lastIdentifiedUserID = "u1"

        let effect = plugin.reduce(
            state: &state,
            action: .analytics(.setOptedOut(true))
        )
        await runEffect(effect)

        #expect(state.analytics.isOptedOut == true)
        #expect(state.analytics.lastIdentifiedUserID == nil)
        let resets = await service.resetCount
        #expect(resets == 1)
    }

    @Test(".setOptedOut(false) clears flag without service call")
    func optInClearsFlagOnly() async {
        let service = RecordingAnalyticsService()
        let plugin = makePlugin(service: service)
        var state = TestState()
        state.analytics.isOptedOut = true

        let effect = plugin.reduce(
            state: &state,
            action: .analytics(.setOptedOut(false))
        )

        #expect(state.analytics.isOptedOut == false)
        #expect(effect == nil)
        let resets = await service.resetCount
        #expect(resets == 0)
    }

    // MARK: - Auto-identify

    @Test("auto-identify fires on nil → userID transition")
    func autoIdentifyOnSignIn() async {
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
    func autoIdentifyOnUserIDChange() async {
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
    func autoIdentifyOnSignOut() async {
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
    func autoIdentifyStable() async {
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
    func autoIdentifyPropertiesFromState() async {
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
    func autoIdentifyPausedWhenOptedOut() async {
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
    func optInReIdentifies() async {
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
        await runEffect(
            plugin.reduce(state: &state, action: .analytics(.setOptedOut(false)))
        )
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
    func autoIdentifyOnPropertiesChange() async {
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

    @Test("auto-identify is a no-op when both userID and userProperties are stable")
    func autoIdentifyStableProperties() async {
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
    func autoIdentifyPropertiesChangeWhileOptedOut() async {
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
    func explicitIdentifyRecordsPropertiesForAutoPath() async {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<TestState>(
            userID: { $0.userID },
            userProperties: { _ in ["plan": .string("pro")] }
        )
        let plugin = makePlugin(service: service, identity: identity)
        var state = TestState()
        state.userID = "u1"

        await runEffect(
            plugin.reduce(
                state: &state,
                action: .analytics(.identify(userID: "u1", properties: ["plan": .string("pro")]))
            )
        )
        plugin.afterReduce(state: &state, action: .unrelated)
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.properties["plan"] == .string("pro"))
        #expect(state.analytics.lastIdentifiedProperties == ["plan": .string("pro")])
    }

    // MARK: - Flush

    @Test("flush awaits pending tasks and calls service.flush")
    func flushDrainsAndFlushes() async {
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

    // MARK: - Lifting (root ↔ analytics action plumbing)

    @Test("reduce returns nil for non-analytics actions")
    func reduceIgnoresUnrelated() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(state: &state, action: .unrelated)
        #expect(effect == nil)
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
