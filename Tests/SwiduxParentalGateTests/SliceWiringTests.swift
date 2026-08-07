//
//  SliceWiringTests.swift
//  SwiduxParentalGateTests
//
//  Compiles the wiring `HowToAddAParentalGate.md` documents. See the companion suite
//  in `SwiduxAnalyticsTests` for why declaring the root is itself the assertion.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxParentalGate

// Mirrors the `AppState` shape from `HowToAddAParentalGate.md` Step 2.
@Swidux
nonisolated struct ParentalGateSliceRoot: Equatable, Sendable {
    @Slice var parentalGate: ParentalGateState = .init()
    var unrelated: Int = 0
}

@Suite("ParentalGate @Slice wiring")
@MainActor
struct ParentalGateSliceWiringTests {
    /// Every field off its default, so a property the observer failed to mirror
    /// can't coincidentally survive the round trip.
    private func populated() -> ParentalGateSliceRoot {
        ParentalGateSliceRoot(
            parentalGate: ParentalGateState(
                pendingReason: "purchase",
                challenge: MathChallenge(left: 7, right: 3, op: .times),
                attempts: 2,
                passedReasons: ["settings"],
                cooldownUntil: Date(timeIntervalSince1970: 1_000)
            ),
            unrelated: 7
        )
    }

    @Test("Packing an observer round-trips every field")
    func roundTripsThroughObserver() {
        let original = populated()

        let observer = ParentalGateSliceRoot.makeObserver(from: original)

        #expect(ParentalGateSliceRoot(observer: observer) == original)
    }

    @Test("The slice observer survives a change to a sibling property")
    func sliceObserverIdentityIsStable() {
        let observer = ParentalGateSliceRoot.makeObserver(from: populated())
        let sliceObserver = observer.parentalGate

        var next = ParentalGateSliceRoot(observer: observer)
        next.unrelated += 1
        ParentalGateSliceRoot.apply(next, to: observer)

        #expect(observer.parentalGate === sliceObserver)
    }

    @Test("Applying a snapshot propagates into the slice observer")
    func applyReachesTheSlice() {
        let observer = ParentalGateSliceRoot.makeObserver(from: populated())

        var next = ParentalGateSliceRoot(observer: observer)
        next.parentalGate.attempts = 0
        next.parentalGate.cooldownUntil = nil
        ParentalGateSliceRoot.apply(next, to: observer)

        #expect(observer.parentalGate.attempts == 0)
        #expect(observer.parentalGate.cooldownUntil == nil)
    }
}
