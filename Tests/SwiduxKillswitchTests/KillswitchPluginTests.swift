//
//  KillswitchPluginTests.swift
//  SwiduxKillswitchTests
//
//  Tests for the KillswitchPlugin reducer.
//

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

    @Test("ignores unrelated actions")
    func ignoresUnrelatedActions() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(state: &state, action: .unrelated)
        #expect(effect == nil)
    }

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
            action: .killswitch(.verdictReceived(verdict))
        )
        #expect(effect == nil)
        #expect(state.killswitch.verdict == verdict)
        #expect(state.killswitch.lastFetch != nil)
        #expect(state.killswitch.fetchError == nil)
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

    @Test("fetch returns an effect")
    func fetchReturnsEffect() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .killswitch(.fetch)
        )
        #expect(effect != nil)
    }
}
