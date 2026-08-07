//
//  SliceWiringTests.swift
//  SwiduxFeatureFlagsTests
//
//  `FeatureFlagsState` was the only plugin slice already carrying `@Swidux` when #64
//  was filed, so this suite is a regression guard rather than a fix — it pins the
//  wiring `HowToAddFeatureFlags.md` documents, which nothing in this package
//  compiled outside the Counter example.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxFeatureFlags

// Mirrors the `AppState` shape from `HowToAddFeatureFlags.md` Step 2.
@Swidux
nonisolated struct FeatureFlagsSliceRoot: Equatable, Sendable {
    @Slice var featureFlags: FeatureFlagsState = .init()
    var unrelated: Int = 0
}

@Suite("FeatureFlags @Slice wiring")
@MainActor
struct FeatureFlagsSliceWiringTests {
    /// Every field off its default, so a property the observer failed to mirror
    /// can't coincidentally survive the round trip.
    private func populated() -> FeatureFlagsSliceRoot {
        FeatureFlagsSliceRoot(
            featureFlags: FeatureFlagsState(
                config: FeatureFlagsConfig(
                    version: 3,
                    flags: ["newEditor": .boolean(rollout: 100)]
                ),
                lastFetchedAt: Date(timeIntervalSince1970: 1_000),
                lastFetchError: "timeout",
                isFetching: true,
                localOverrides: ["newEditor": .bool(false)],
                exposedKeys: ["newEditor"],
                resolvedDeviceID: "device-1",
                resolvedUserID: "user-1"
            ),
            unrelated: 7
        )
    }

    @Test("Packing an observer round-trips every field")
    func roundTripsThroughObserver() {
        let original = populated()

        let observer = FeatureFlagsSliceRoot.makeObserver(from: original)

        #expect(FeatureFlagsSliceRoot(observer: observer) == original)
    }

    @Test("The slice observer survives a change to a sibling property")
    func sliceObserverIdentityIsStable() {
        let observer = FeatureFlagsSliceRoot.makeObserver(from: populated())
        let sliceObserver = observer.featureFlags

        var next = FeatureFlagsSliceRoot(observer: observer)
        next.unrelated += 1
        FeatureFlagsSliceRoot.apply(next, to: observer)

        #expect(observer.featureFlags === sliceObserver)
    }

    @Test("Applying a snapshot propagates into the slice observer")
    func applyReachesTheSlice() {
        let observer = FeatureFlagsSliceRoot.makeObserver(from: populated())

        var next = FeatureFlagsSliceRoot(observer: observer)
        next.featureFlags.isFetching = false
        next.featureFlags.lastFetchError = nil
        FeatureFlagsSliceRoot.apply(next, to: observer)

        #expect(observer.featureFlags.isFetching == false)
        #expect(observer.featureFlags.lastFetchError == nil)
    }
}
