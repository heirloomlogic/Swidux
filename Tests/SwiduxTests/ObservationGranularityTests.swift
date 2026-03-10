//
//  ObservationGranularityTests.swift
//  SwiduxTests
//
//  Verifies whether @Observable tracks sub-properties of nested structs
//  independently, or treats the entire struct as one observation point.
//

import Foundation
import Observation
import Synchronization
import Testing

@testable import Swidux

// MARK: - Test Models

/// State as a single struct property on an @Observable class.
/// This mirrors what "framework owns the state" would look like.
@Observable
@MainActor
final class SingleStateStore {
    var state = TestState()
}

/// State split into separate properties on an @Observable class.
/// This mirrors the current Swidux pattern.
@Observable
@MainActor
final class SplitStateStore {
    var items = EntityStore<TestEntity>()
    var extras = EntityStore<TestEntity>()
}

// MARK: - Tests

@Suite("Observation Granularity")
struct ObservationGranularityTests {

    @Test("Single state struct — mutating items triggers observation for extras readers")
    @MainActor
    func singleStateCrossContamination() {
        let store = SingleStateStore()
        let entity = TestEntity(name: "A")

        let extrasObservationFired = Mutex(false)
        withObservationTracking {
            _ = store.state.extras
        } onChange: {
            extrasObservationFired.withLock { $0 = true }
        }

        // Mutate items — does this fire observation for extras?
        store.state.items[entity.id] = entity

        let fired = extrasObservationFired.withLock { $0 }
        #expect(
            fired,
            "Single struct: mutating .items should fire observation for .extras readers (struct is one property)"
        )
    }

    @Test("Split properties — mutating items does NOT trigger observation for extras readers")
    @MainActor
    func splitStateIsolation() {
        let store = SplitStateStore()
        let entity = TestEntity(name: "B")

        let extrasObservationFired = Mutex(false)
        withObservationTracking {
            _ = store.extras
        } onChange: {
            extrasObservationFired.withLock { $0 = true }
        }

        // Mutate items — this should NOT fire observation for extras
        store.items[entity.id] = entity

        let fired = extrasObservationFired.withLock { $0 }
        #expect(
            !fired,
            "Split properties: mutating .items should NOT fire observation for .extras readers"
        )
    }
}
