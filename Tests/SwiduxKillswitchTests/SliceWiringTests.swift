//
//  SliceWiringTests.swift
//  SwiduxKillswitchTests
//
//  Compiles the wiring `HowToAddAVersionKillswitch.md` documents. See the companion
//  suite in `SwiduxAnalyticsTests` for why declaring the root is itself the assertion.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxKillswitch

// Mirrors the `AppState` shape from `HowToAddAVersionKillswitch.md` Step 2.
@Swidux
nonisolated struct KillswitchSliceRoot: Equatable, Sendable {
    @Slice var killswitch: KillswitchState = .init()
    var unrelated: Int = 0
}

@Suite("Killswitch @Slice wiring")
@MainActor
struct KillswitchSliceWiringTests {
    /// Every field off its default, so a property the observer failed to mirror
    /// can't coincidentally survive the round trip.
    private func populated() -> KillswitchSliceRoot {
        KillswitchSliceRoot(
            killswitch: KillswitchState(
                verdict: .blocked(
                    title: "Update required",
                    message: "This version is no longer supported.",
                    updateURL: URL(string: "https://example.com")
                ),
                lastFetch: Date(timeIntervalSince1970: 1_000),
                fetchError: "timeout"
            ),
            unrelated: 7
        )
    }

    @Test("Packing an observer round-trips every field")
    func roundTripsThroughObserver() {
        let original = populated()

        let observer = KillswitchSliceRoot.makeObserver(from: original)

        #expect(KillswitchSliceRoot(observer: observer) == original)
    }

    @Test("The slice observer survives a change to a sibling property")
    func sliceObserverIdentityIsStable() {
        let observer = KillswitchSliceRoot.makeObserver(from: populated())
        let sliceObserver = observer.killswitch

        var next = KillswitchSliceRoot(observer: observer)
        next.unrelated += 1
        KillswitchSliceRoot.apply(next, to: observer)

        #expect(observer.killswitch === sliceObserver)
    }

    @Test("Applying a snapshot propagates into the slice observer")
    func applyReachesTheSlice() {
        let observer = KillswitchSliceRoot.makeObserver(from: populated())

        var next = KillswitchSliceRoot(observer: observer)
        next.killswitch.verdict = .allowed
        next.killswitch.fetchError = nil
        KillswitchSliceRoot.apply(next, to: observer)

        #expect(observer.killswitch.verdict == .allowed)
        #expect(observer.killswitch.fetchError == nil)
        // `isBlocked` is computed, so it lives on the struct and not the observer —
        // read it back through a packed snapshot.
        #expect(KillswitchSliceRoot(observer: observer).killswitch.isBlocked == false)
    }
}
