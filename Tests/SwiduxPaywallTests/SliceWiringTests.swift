//
//  SliceWiringTests.swift
//  SwiduxPaywallTests
//
//  Compiles the wiring `HowToAddAPaywall.md` documents. See the companion suite in
//  `SwiduxAnalyticsTests` for why declaring the root is itself the assertion.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxPaywall

// Mirrors the `AppState` shape from `HowToAddAPaywall.md` Step 2.
@Swidux
nonisolated struct PaywallSliceRoot: Equatable, Sendable {
    @Slice var paywall: PaywallState = .init()
    var unrelated: Int = 0
}

@Suite("Paywall @Slice wiring")
@MainActor
struct PaywallSliceWiringTests {
    /// Every field off its default, so a property the observer failed to mirror
    /// can't coincidentally survive the round trip.
    private func populated() -> PaywallSliceRoot {
        PaywallSliceRoot(
            paywall: PaywallState(
                isPro: true,
                hasPermanentLicense: true,
                isPresented: true,
                requestedReason: "export",
                isLoading: true,
                error: "network",
                isCustomerCenterPresented: true,
                isObservingCustomerInfo: true
            ),
            unrelated: 7
        )
    }

    @Test("Packing an observer round-trips every field")
    func roundTripsThroughObserver() {
        let original = populated()

        let observer = PaywallSliceRoot.makeObserver(from: original)

        #expect(PaywallSliceRoot(observer: observer) == original)
    }

    @Test("The slice observer survives a change to a sibling property")
    func sliceObserverIdentityIsStable() {
        let observer = PaywallSliceRoot.makeObserver(from: populated())
        let sliceObserver = observer.paywall

        var next = PaywallSliceRoot(observer: observer)
        next.unrelated += 1
        PaywallSliceRoot.apply(next, to: observer)

        #expect(observer.paywall === sliceObserver)
    }

    @Test("Applying a snapshot propagates into the slice observer")
    func applyReachesTheSlice() {
        let observer = PaywallSliceRoot.makeObserver(from: populated())

        var next = PaywallSliceRoot(observer: observer)
        next.paywall.isPresented = false
        next.paywall.requestedReason = nil
        PaywallSliceRoot.apply(next, to: observer)

        #expect(observer.paywall.isPresented == false)
        #expect(observer.paywall.requestedReason == nil)
    }
}
