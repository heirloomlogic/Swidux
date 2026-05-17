//
//  SimulatedPaywallServiceTests.swift
//  SwiduxPaywallTests
//

import Foundation
import Swidux
import Testing

@testable import SwiduxPaywall

@Suite("SimulatedPaywallService")
struct SimulatedPaywallServiceTests {
    @Test("starts free by default")
    func startsFree() async throws {
        let service = SimulatedPaywallService()
        let snapshot = try await service.customerInfo()
        #expect(snapshot == EntitlementSnapshot())
    }

    @Test("customerInfoStream yields the current snapshot immediately")
    func streamYieldsCurrentImmediately() async {
        let service = SimulatedPaywallService(isPro: true)
        var iterator = service.customerInfoStream().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == EntitlementSnapshot(isPro: true))
    }

    @Test("grantPro pushes a pro snapshot to a live subscriber")
    func grantProBroadcasts() async {
        let service = SimulatedPaywallService()
        var iterator = service.customerInfoStream().makeAsyncIterator()
        _ = await iterator.next()  // initial free snapshot

        await service.grantPro()
        let next = await iterator.next()
        #expect(next == EntitlementSnapshot(isPro: true))
    }

    @Test("grantTrial yields isPro and survives a later refresh")
    func grantTrialSurvivesRefresh() async throws {
        let service = SimulatedPaywallService()
        await service.grantTrial()
        let refreshed = try await service.customerInfo()
        #expect(refreshed.isPro == true)
    }

    @Test("grantPermanentLicense and setFree update entitlement")
    func permanentAndFree() async throws {
        let service = SimulatedPaywallService()
        await service.grantPermanentLicense()
        #expect(try await service.customerInfo() == EntitlementSnapshot(hasPermanentLicense: true))

        await service.setFree()
        #expect(try await service.customerInfo() == EntitlementSnapshot())
    }

    @Test("restorePurchases throws when restore is set to fail")
    func restoreFails() async {
        let service = SimulatedPaywallService(isPro: true)
        await service.setRestoreShouldFail(true)
        await #expect(throws: SimulatedPaywallError.self) {
            try await service.restorePurchases()
        }
    }

    @Test("restorePurchases returns the current snapshot on success")
    func restoreSucceeds() async throws {
        let service = SimulatedPaywallService()
        await service.grantPro()
        let restored = try await service.restorePurchases()
        #expect(restored == EntitlementSnapshot(isPro: true))
    }

    @Test("customerInfo throws when refresh is set to fail")
    func refreshFails() async {
        let service = SimulatedPaywallService()
        await service.setRefreshShouldFail(true)
        await #expect(throws: SimulatedPaywallError.self) {
            try await service.customerInfo()
        }
    }

    @Test("artificialDelay actually delays customerInfo")
    func artificialDelayApplies() async throws {
        let service = SimulatedPaywallService()
        await service.setArtificialDelay(.milliseconds(80))
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await service.customerInfo()
        }
        #expect(elapsed >= .milliseconds(80))
    }
}

@Suite("SimulatedPaywallService + PaywallPlugin integration")
@MainActor
struct SimulatedPaywallServiceIntegrationTests {
    @Test("granting pro flows a customerInfoUpdated through the plugin pipeline")
    func grantProReachesState() async {
        let service = SimulatedPaywallService()
        await service.grantPro()
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let actions = await collectActions(from: effect)

        for action in actions {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(state.paywall.isPro == true)
    }

    @Test("a simulated refresh failure surfaces as a paywall error")
    func refreshFailureSurfaces() async {
        let service = SimulatedPaywallService()
        await service.setRefreshShouldFail(true)
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let actions = await collectActions(from: effect)
        for action in actions {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(state.paywall.error != nil)
        #expect(state.paywall.isLoading == false)
    }
}
