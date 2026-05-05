//
//  PaywallPluginTests.swift
//  SwiduxPaywallTests
//
//  Tests for the PaywallPlugin reducer.
//

import Swidux
import Testing

@testable import SwiduxPaywall

@Suite("PaywallPlugin")
@MainActor
struct PaywallPluginTests {
    struct TestState: Sendable, Equatable {
        var paywall = PaywallState()
    }

    enum TestAction: Sendable {
        case paywall(PaywallAction)
        case unrelated
    }

    func makePlugin(
        service: any PaywallService = MockPaywallService()
    ) -> PaywallPlugin<TestState, TestAction> {
        PaywallPlugin(
            state: \.paywall,
            action: TestAction.paywall,
            extractAction: {
                if case .paywall(let a) = $0 { return a }
                return nil
            },
            service: service,
            openURL: { _ in }
        )
    }

    @Test("request presents paywall")
    func requestPresentsPaywall() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.request(reason: "premium-feature"))
        )
        #expect(effect == nil)
        #expect(state.paywall.isPresented == true)
        #expect(state.paywall.requestedReason == "premium-feature")
    }

    @Test("dismiss hides paywall and returns refresh effect")
    func dismissHidesPaywallAndReturnsRefreshEffect() {
        let plugin = makePlugin()
        var state = TestState()
        state.paywall.isPresented = true
        state.paywall.requestedReason = "premium-feature"

        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.dismiss)
        )
        #expect(state.paywall.isPresented == false)
        #expect(state.paywall.requestedReason == nil)
        #expect(effect != nil)
    }

    @Test("customerInfoUpdated sets isPro and hasPermanentLicense")
    func customerInfoUpdatedSetsEntitlements() {
        let plugin = makePlugin()
        var state = TestState()
        state.paywall.isLoading = true

        let snapshot = EntitlementSnapshot(isPro: true, hasPermanentLicense: true)
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.customerInfoUpdated(snapshot))
        )
        #expect(effect == nil)
        #expect(state.paywall.isPro == true)
        #expect(state.paywall.hasPermanentLicense == true)
        #expect(state.paywall.isLoading == false)
        #expect(state.paywall.error == nil)
    }

    @Test("refreshFailed sets error and clears loading")
    func refreshFailedSetsError() {
        let plugin = makePlugin()
        var state = TestState()
        state.paywall.isLoading = true

        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.refreshFailed("Something went wrong"))
        )
        #expect(effect == nil)
        #expect(state.paywall.isLoading == false)
        #expect(state.paywall.error == "Something went wrong")
    }

    @Test("isGateSatisfied when isPro or hasPermanentLicense")
    func isGateSatisfied() {
        var state = PaywallState()
        #expect(state.isGateSatisfied == false)

        state.isPro = true
        #expect(state.isGateSatisfied == true)

        state.isPro = false
        state.hasPermanentLicense = true
        #expect(state.isGateSatisfied == true)

        state.isPro = true
        #expect(state.isGateSatisfied == true)
    }

    @Test("restorePurchases sets loading state")
    func restorePurchasesSetsLoading() {
        let plugin = makePlugin()
        var state = TestState()

        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.restorePurchases)
        )
        #expect(state.paywall.isLoading == true)
        #expect(effect != nil)
    }
}
