//
//  AnalyticsIdentityTests.swift
//  SwiduxAnalyticsTests
//

import Foundation
import Swidux
import Testing

@testable import SwiduxAnalytics

@Suite("AnalyticsIdentity keypath inits")
@MainActor
struct AnalyticsIdentityTests {
    // MARK: - Fixtures

    struct State: Sendable, Equatable {
        var analytics = AnalyticsState()
        var deviceID: String = ""
        var userID: String? = nil
    }

    enum Action: Sendable, Equatable {
        case analytics(AnalyticsAction)
        case touch
    }

    func makePlugin(
        service: any AnalyticsService,
        identity: AnalyticsIdentity<State>
    ) -> AnalyticsPlugin<State, Action> {
        AnalyticsPlugin(
            state: \.analytics,
            action: Action.analytics,
            extractAction: {
                if case .analytics(let a) = $0 { return a }
                return nil
            },
            service: service,
            mapper: .none,
            identity: identity
        )
    }

    // MARK: - Non-optional keypath overload (device-stable identity)

    @Test("non-optional keypath identifies from an always-present property")
    func nonOptionalKeyPathIdentifies() async {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<State>(
            userID: \.deviceID,
            userProperties: { _ in ["tier": .string("free")] }
        )
        let plugin = makePlugin(service: service, identity: identity)
        var state = State()
        state.deviceID = "device-abc"

        plugin.afterReduce(state: &state, action: .touch)
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.userID == "device-abc")
        #expect(calls.first?.properties["tier"] == .string("free"))
        #expect(state.analytics.lastIdentifiedUserID == "device-abc")
    }

    @Test("non-optional keypath is a no-op when the ID is unchanged")
    func nonOptionalKeyPathStable() async {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<State>(userID: \.deviceID)
        let plugin = makePlugin(service: service, identity: identity)
        var state = State()
        state.deviceID = "device-abc"
        state.analytics.lastIdentifiedUserID = "device-abc"

        plugin.afterReduce(state: &state, action: .touch)
        await plugin.flush()

        let calls = await service.identifyCalls
        let resets = await service.resetCount
        #expect(calls.isEmpty)
        #expect(resets == 0)
    }

    // MARK: - Optional keypath overload (auth) — regression guard

    @Test("optional keypath fires identify on nil → value")
    func optionalKeyPathIdentifiesOnSignIn() async {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<State>(userID: \.userID)
        let plugin = makePlugin(service: service, identity: identity)
        var state = State()
        state.userID = "u1"

        plugin.afterReduce(state: &state, action: .touch)
        await plugin.flush()

        let calls = await service.identifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.userID == "u1")
    }

    @Test("optional keypath fires reset on value → nil")
    func optionalKeyPathResetsOnSignOut() async {
        let service = RecordingAnalyticsService()
        let identity = AnalyticsIdentity<State>(userID: \.userID)
        let plugin = makePlugin(service: service, identity: identity)
        var state = State()
        state.analytics.lastIdentifiedUserID = "u1"
        state.userID = nil

        plugin.afterReduce(state: &state, action: .touch)
        await plugin.flush()

        let resets = await service.resetCount
        #expect(resets == 1)
        #expect(state.analytics.lastIdentifiedUserID == nil)
    }

    // MARK: - Overload resolution

    @Test("each keypath value type selects its intended overload, unambiguously")
    func overloadResolution() async {
        let device = AnalyticsIdentity<State>(userID: \.deviceID)
        let auth = AnalyticsIdentity<State>(userID: \.userID)

        var state = State()
        state.deviceID = "d1"
        state.userID = nil

        #expect(device.userID(state) == "d1")
        #expect(auth.userID(state) == nil)
    }
}
