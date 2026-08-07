//
//  SliceWiringTests.swift
//  SwiduxAnalyticsTests
//
//  Compiles the wiring `HowToAddAnalytics.md` documents. `AnalyticsState` has to
//  carry `@Swidux` for `@Slice` to resolve its observer, and every stored property
//  needs an inline default so the parent's generated init can default the child to
//  `AnalyticsStateObserver()`. Neither held before #64, and nothing caught it: the
//  macro tests compare expansion *strings* without type-checking them, and the other
//  suites in this target declare `AnalyticsState` as a plain leaf.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxAnalytics

// Mirrors the `AppState` shape from `HowToAddAnalytics.md` Step 2. Declaring it is
// the assertion — it fails to compile if the slice loses its observer.
@Swidux
nonisolated struct AnalyticsSliceRoot: Equatable, Sendable {
    @Slice var analytics: AnalyticsState = .init()
    var unrelated: Int = 0
}

@Suite("Analytics @Slice wiring")
@MainActor
struct AnalyticsSliceWiringTests {
    /// A state with every field off its default, so a property the observer failed to
    /// mirror can't coincidentally survive the round trip.
    private func populated() -> AnalyticsSliceRoot {
        var analytics = AnalyticsState(isOptedOut: true, currentScreen: "library")
        analytics.recordIdentified(userID: "u-42", properties: ["plan": .string("pro")])
        return AnalyticsSliceRoot(analytics: analytics, unrelated: 7)
    }

    @Test("Packing an observer round-trips every field, bookkeeping included")
    func roundTripsThroughObserver() {
        let original = populated()

        let observer = AnalyticsSliceRoot.makeObserver(from: original)
        let packed = AnalyticsSliceRoot(observer: observer)

        #expect(packed == original)
        // Spelled out, because `internal(set)` bookkeeping resetting to its default is
        // the specific failure that would make the plugin re-fire `identify` forever.
        #expect(packed.analytics.lastIdentifiedUserID == "u-42")
        #expect(packed.analytics.lastIdentifiedProperties == ["plan": .string("pro")])
    }

    @Test("The slice observer survives a change to a sibling property")
    func sliceObserverIdentityIsStable() {
        let observer = AnalyticsSliceRoot.makeObserver(from: populated())
        let sliceObserver = observer.analytics

        var next = AnalyticsSliceRoot(observer: observer)
        next.unrelated += 1
        AnalyticsSliceRoot.apply(next, to: observer)

        // `@Slice` stores the child as `let` precisely so views observing the slice
        // don't re-render when a sibling changes. A fresh instance here means the
        // property was demoted to a leaf.
        #expect(observer.analytics === sliceObserver)
    }

    @Test("Applying a snapshot propagates into the slice observer")
    func applyReachesTheSlice() {
        let observer = AnalyticsSliceRoot.makeObserver(from: populated())

        var next = AnalyticsSliceRoot(observer: observer)
        next.analytics.currentScreen = "settings"
        next.analytics.isOptedOut = false
        AnalyticsSliceRoot.apply(next, to: observer)

        #expect(observer.analytics.currentScreen == "settings")
        #expect(observer.analytics.isOptedOut == false)
    }
}
