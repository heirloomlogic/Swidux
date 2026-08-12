//
//  PaywallPluginTests.swift
//  SwiduxPaywallTests
//
//  Tests for the PaywallPlugin reducer.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxPaywall

@Suite("PaywallPlugin")
@MainActor
struct PaywallPluginTests {
    // MARK: - Reducer state transitions

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

    @Test("customerInfoUpdated keeps unchanged entitlement but still clears loading/error")
    func customerInfoUpdatedRedundantCycleStillBookkeeps() {
        let plugin = makePlugin()
        var state = TestState()
        state.paywall.isPro = true
        state.paywall.isLoading = true
        state.paywall.error = "stale"

        let snapshot = EntitlementSnapshot(isPro: true, hasPermanentLicense: false)
        _ = plugin.reduce(
            state: &state,
            action: .paywall(.customerInfoUpdated(snapshot))
        )

        // Meaningful payload unchanged.
        #expect(state.paywall.isPro == true)
        #expect(state.paywall.hasPermanentLicense == false)
        // Bookkeeping ran unconditionally.
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

    @Test("presentCustomerCenter sets isCustomerCenterPresented")
    func presentCustomerCenter() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.presentCustomerCenter)
        )
        #expect(effect == nil)
        #expect(state.paywall.isCustomerCenterPresented == true)
    }

    @Test("dismissCustomerCenter clears isCustomerCenterPresented")
    func dismissCustomerCenter() {
        let plugin = makePlugin()
        var state = TestState()
        state.paywall.isCustomerCenterPresented = true
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.dismissCustomerCenter)
        )
        #expect(effect == nil)
        #expect(state.paywall.isCustomerCenterPresented == false)
    }

    @Test("ignores unrelated actions")
    func ignoresUnrelatedActions() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(state: &state, action: .unrelated)
        #expect(effect == nil)
        #expect(state == TestState())
    }

    @Test("refreshCustomerInfo sets loading and returns effect")
    func refreshCustomerInfoSetsLoading() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.refreshCustomerInfo)
        )
        #expect(state.paywall.isLoading == true)
        #expect(effect != nil)
    }

    @Test("observeCustomerInfo returns effect and marks the stream as active")
    func observeCustomerInfoReturnsEffect() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.observeCustomerInfo)
        )
        #expect(effect != nil)
        #expect(state.paywall.isObservingCustomerInfo)
    }

    @Test("a second observeCustomerInfo does not start a duplicate stream")
    func observeCustomerInfoIsIdempotent() {
        let plugin = makePlugin()
        var state = TestState()

        let first = plugin.reduce(state: &state, action: .paywall(.observeCustomerInfo))
        #expect(first != nil)

        let second = plugin.reduce(state: &state, action: .paywall(.observeCustomerInfo))
        #expect(second == nil)
    }

    // MARK: - Effects: dismiss

    @Test("dismiss effect dispatches refreshCustomerInfo")
    func dismissEffectDispatchesRefresh() async throws {
        let plugin = makePlugin()
        var state = TestState()
        state.paywall.isPresented = true
        let effect = plugin.reduce(state: &state, action: .paywall(.dismiss))

        let actions = try await collectActions(from: effect)
        #expect(actions.count == 1)
        if case .refreshCustomerInfo = actions.first {
        } else {
            Issue.record("Expected refreshCustomerInfo, got \(actions)")
        }
    }

    // MARK: - Effects: refreshCustomerInfo

    @Test("refreshCustomerInfo success dispatches customerInfoUpdated")
    func refreshCustomerInfoSuccess() async throws {
        let service = MockPaywallService(isPro: true, hasPermanentLicense: false)
        let plugin = makePlugin(service: service)
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.refreshCustomerInfo)
        )

        let actions = try await collectActions(from: effect)
        #expect(actions.count == 1)
        if case .customerInfoUpdated(let snapshot) = actions.first {
            #expect(snapshot.isPro == true)
            #expect(snapshot.hasPermanentLicense == false)
        } else {
            Issue.record("Expected customerInfoUpdated, got \(actions)")
        }
    }

    @Test("refreshCustomerInfo failure dispatches refreshFailed")
    func refreshCustomerInfoFailure() async throws {
        let service = ThrowingPaywallService(error: TestError.boom)
        let plugin = makePlugin(service: service)
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.refreshCustomerInfo)
        )

        let actions = try await collectActions(from: effect)
        #expect(actions.count == 1)
        if case .refreshFailed(let message) = actions.first {
            #expect(message.isEmpty == false)
        } else {
            Issue.record("Expected refreshFailed, got \(actions)")
        }
    }

    // MARK: - Effects: restorePurchases

    @Test("restorePurchases success dispatches customerInfoUpdated")
    func restorePurchasesSuccess() async throws {
        let service = MockPaywallService(isPro: false, hasPermanentLicense: true)
        let plugin = makePlugin(service: service)
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.restorePurchases)
        )

        let actions = try await collectActions(from: effect)
        #expect(actions.count == 1)
        if case .customerInfoUpdated(let snapshot) = actions.first {
            #expect(snapshot.isPro == false)
            #expect(snapshot.hasPermanentLicense == true)
        } else {
            Issue.record("Expected customerInfoUpdated, got \(actions)")
        }
    }

    @Test("restorePurchases failure dispatches refreshFailed")
    func restorePurchasesFailure() async throws {
        let service = ThrowingPaywallService(error: TestError.boom)
        let plugin = makePlugin(service: service)
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.restorePurchases)
        )

        let actions = try await collectActions(from: effect)
        #expect(actions.count == 1)
        if case .refreshFailed(let message) = actions.first {
            #expect(message.isEmpty == false)
        } else {
            Issue.record("Expected refreshFailed, got \(actions)")
        }
    }

    // MARK: - Effects: observeCustomerInfo

    @Test("observeCustomerInfo emits one customerInfoUpdated per stream value")
    func observeCustomerInfoStreamsUpdates() async throws {
        let snapshots = [
            EntitlementSnapshot(isPro: false),
            EntitlementSnapshot(isPro: true),
            EntitlementSnapshot(isPro: true, hasPermanentLicense: true),
        ]
        let service = StreamingPaywallService(snapshots: snapshots)
        let plugin = makePlugin(service: service)
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.observeCustomerInfo)
        )

        let actions = try await collectActions(from: effect)
        let received = actions.compactMap { action -> EntitlementSnapshot? in
            if case .customerInfoUpdated(let snapshot) = action { return snapshot }
            return nil
        }
        #expect(received == snapshots)
        // Plus the end-of-stream action, which is what releases the guard.
        #expect(actions.count == snapshots.count + 1)
    }

    @Test("observeCustomerInfo finishes cleanly when stream is empty")
    func observeCustomerInfoEmptyStream() async throws {
        let plugin = makePlugin(service: MockPaywallService())
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.observeCustomerInfo)
        )

        let actions = try await collectActions(from: effect)
        #expect(actions.count == 1)
        guard case .customerInfoStreamEnded = try #require(actions.first) else {
            Issue.record("an empty stream must still report that it ended")
            return
        }
    }

    @Test("a finished stream releases the guard, so observation can restart")
    func finishedStreamAllowsReobserving() async throws {
        // `MockPaywallService` finishes immediately, which is also what a real
        // service does on teardown. Latched, the guard would leave the app with
        // no live entitlement updates and no way to ask for them again — the
        // gate then reflects whatever the last snapshot said, forever.
        let plugin = makePlugin(service: MockPaywallService())
        var state = TestState()

        let first = plugin.reduce(state: &state, action: .paywall(.observeCustomerInfo))
        #expect(first != nil)
        #expect(state.paywall.isObservingCustomerInfo)

        _ = plugin.reduce(state: &state, action: .paywall(.customerInfoStreamEnded))
        #expect(!state.paywall.isObservingCustomerInfo)

        let second = plugin.reduce(state: &state, action: .paywall(.observeCustomerInfo))
        #expect(second != nil, "a stream that ended must be startable again")
    }

    // MARK: - Effects: openManageSubscriptions

    @Test("openManageSubscriptions opens the App Store subscriptions URL")
    func openManageSubscriptionsCallsOpenURL() async throws {
        let captured = URLCaptureBox()
        let plugin = makePlugin(openURL: { url in await captured.record(url) })
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .paywall(.openManageSubscriptions)
        )
        _ = try await collectActions(from: effect)

        let urls = await captured.urls
        #expect(urls.count == 1)
        #expect(urls.first?.absoluteString == "itms-apps://apps.apple.com/account/subscriptions")
    }
}

// MARK: - Test fixtures

private enum TestError: Error {
    case boom
}

private struct ThrowingPaywallService: PaywallService {
    let error: any Error

    func customerInfo() async throws -> EntitlementSnapshot { throw error }
    func customerInfoStream() -> AsyncStream<EntitlementSnapshot> {
        AsyncStream { $0.finish() }
    }
    func restorePurchases() async throws -> EntitlementSnapshot { throw error }
}

private struct StreamingPaywallService: PaywallService {
    let snapshots: [EntitlementSnapshot]

    func customerInfo() async throws -> EntitlementSnapshot {
        snapshots.last ?? EntitlementSnapshot()
    }

    func customerInfoStream() -> AsyncStream<EntitlementSnapshot> {
        let snapshots = self.snapshots
        return AsyncStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
    }

    func restorePurchases() async throws -> EntitlementSnapshot {
        snapshots.last ?? EntitlementSnapshot()
    }
}

private actor URLCaptureBox {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}
