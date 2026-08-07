//
//  SliceWiringTests.swift
//  SwiduxPersistenceTests
//
//  Compiles the wiring `PersistenceState`'s own doc comment documents. This target
//  also proves `@Swidux` is reachable here, which `ObservableFixtures.swift` once
//  claimed it wasn't — `NotesState` keeps its hand-written conformance on purpose,
//  to exercise the hand-rolled path.
//
//  `hydrationPhase` is the interesting one: `HydrationPhase` is nested inside
//  `PersistenceState`, and the generated observer is a peer at file scope, so the
//  property has to be annotated with the qualified name for this to compile at all.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxPersistence

// Mirrors the `AppState` shape from the `PersistenceState` doc comment.
@Swidux
nonisolated struct PersistenceSliceRoot: Equatable, Sendable {
    @Slice var persistence: PersistenceState = .init()
    var unrelated: Int = 0
}

@Suite("Persistence @Slice wiring")
@MainActor
struct PersistenceSliceWiringTests {
    /// Every field off its default, so a property the observer failed to mirror
    /// can't coincidentally survive the round trip.
    private func populated() -> PersistenceSliceRoot {
        PersistenceSliceRoot(
            persistence: PersistenceState(
                hydrationPhase: .failed("disk"),
                syncMode: .iCloud,
                syncStatus: .unavailableNotSignedIn
            ),
            unrelated: 7
        )
    }

    @Test("Packing an observer round-trips every field")
    func roundTripsThroughObserver() {
        let original = populated()

        let observer = PersistenceSliceRoot.makeObserver(from: original)

        // `hydrationPhase` carries an associated value here, so equality passing also
        // proves the qualified annotation reached the observer as a real
        // `PersistenceState.HydrationPhase`.
        #expect(PersistenceSliceRoot(observer: observer) == original)
    }

    @Test("The slice observer survives a change to a sibling property")
    func sliceObserverIdentityIsStable() {
        let observer = PersistenceSliceRoot.makeObserver(from: populated())
        let sliceObserver = observer.persistence

        var next = PersistenceSliceRoot(observer: observer)
        next.unrelated += 1
        PersistenceSliceRoot.apply(next, to: observer)

        #expect(observer.persistence === sliceObserver)
    }

    @Test("Applying a snapshot propagates into the slice observer")
    func applyReachesTheSlice() {
        let observer = PersistenceSliceRoot.makeObserver(from: populated())

        var next = PersistenceSliceRoot(observer: observer)
        next.persistence.hydrationPhase = .ready
        next.persistence.syncStatus = .syncing
        PersistenceSliceRoot.apply(next, to: observer)

        #expect(observer.persistence.hydrationPhase == .ready)
        #expect(observer.persistence.syncStatus == .syncing)
    }
}
