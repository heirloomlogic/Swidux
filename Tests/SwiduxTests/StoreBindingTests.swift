//
//  StoreBindingTests.swift
//  SwiduxTests
//
//  Tests for Store.binding(_:sending:).
//

import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing

@testable import Swidux

/// Sendable flag for capturing observation-tracking fires from a non-isolated
/// `onChange` closure.
private final class TrackingFlag: Sendable {
    let storage = Mutex(false)
    func mark() { storage.withLock { $0 = true } }
    var fired: Bool { storage.withLock { $0 } }
}

// MARK: - Fixture state

/// Two-property state so we can verify per-property observation: changing
/// `extras` must not invalidate observation of `items`.
private struct BindingTestState: Sendable, Equatable {
    var items: EntityStore<TestEntity> = EntityStore()
    var extras: EntityStore<TestEntity> = EntityStore()
}

@Observable
@MainActor
private final class BindingTestStateObserver {
    var items: EntityStore<TestEntity>
    var extras: EntityStore<TestEntity>

    init(
        items: EntityStore<TestEntity> = EntityStore(),
        extras: EntityStore<TestEntity> = EntityStore()
    ) {
        self.items = items
        self.extras = extras
    }
}

extension BindingTestState: SwiduxObservable {
    typealias Observer = BindingTestStateObserver

    @MainActor
    init(observer: BindingTestStateObserver) {
        self.items = observer.items
        self.extras = observer.extras
    }

    @MainActor
    static func makeObserver(from state: BindingTestState) -> BindingTestStateObserver {
        BindingTestStateObserver(items: state.items, extras: state.extras)
    }

    @MainActor
    static func apply(_ snapshot: BindingTestState, to observer: BindingTestStateObserver) {
        observer.items = snapshot.items
        observer.extras = snapshot.extras
    }

    @MainActor
    static func applyRestore(from snapshot: BindingTestState, to current: inout BindingTestState) {
        current.items.restore(from: snapshot.items)
        current.extras.restore(from: snapshot.extras)
    }
}

private enum BindingTestAction: Sendable, Equatable {
    case replaceItems(EntityStore<TestEntity>)
    case replaceExtras(EntityStore<TestEntity>)
}

private func bindingTestReducer(
    state: inout BindingTestState,
    action: BindingTestAction
) -> Effect<BindingTestAction>? {
    switch action {
    case .replaceItems(let next):
        state.items = next
    case .replaceExtras(let next):
        state.extras = next
    }
    return nil
}

// MARK: - Tests

@Suite("Store.binding")
struct StoreBindingTests {
    @Test("get reads current value through the observer tree")
    @MainActor
    func getReadsCurrentValue() {
        let store = Store<BindingTestState, BindingTestAction>(
            initialState: BindingTestState(),
            reducer: bindingTestReducer
        )

        let entity = TestEntity(name: "Initial")
        store.send(.replaceItems(EntityStore([entity])))

        let binding = store.binding(\.items) { .replaceItems($0) }

        #expect(binding.wrappedValue[entity.id]?.name == "Initial")
    }

    @Test("set dispatches the constructed action")
    @MainActor
    func setDispatchesAction() {
        let store = Store<BindingTestState, BindingTestAction>(
            initialState: BindingTestState(),
            reducer: bindingTestReducer
        )

        let binding = store.binding(\.items) { .replaceItems($0) }

        let entity = TestEntity(name: "FromBinding")
        binding.wrappedValue = EntityStore([entity])

        #expect(store.items[entity.id]?.name == "FromBinding")
    }

    @Test("get sees updates after subsequent dispatches")
    @MainActor
    func getReflectsLaterDispatches() {
        let store = Store<BindingTestState, BindingTestAction>(
            initialState: BindingTestState(),
            reducer: bindingTestReducer
        )

        let binding = store.binding(\.items) { .replaceItems($0) }

        let first = TestEntity(name: "First")
        store.send(.replaceItems(EntityStore([first])))
        #expect(binding.wrappedValue.count == 1)

        let second = TestEntity(name: "Second")
        store.send(.replaceItems(EntityStore([first, second])))
        #expect(binding.wrappedValue.count == 2)
    }

    @Test("reads register Observation tracking for the bound property only")
    @MainActor
    func bindingReadIsTracked() async {
        let store = Store<BindingTestState, BindingTestAction>(
            initialState: BindingTestState(),
            reducer: bindingTestReducer
        )

        let binding = store.binding(\.items) { .replaceItems($0) }

        let trackingFired = TrackingFlag()
        withObservationTracking {
            _ = binding.wrappedValue
        } onChange: {
            trackingFired.mark()
        }

        let entity = TestEntity(name: "Tracked")
        store.send(.replaceItems(EntityStore([entity])))

        // Observation callbacks fire asynchronously on the next runloop tick.
        await Task.yield()
        #expect(trackingFired.fired)
    }

    @Test("mutating an unrelated property does not invalidate the bound read")
    @MainActor
    func unrelatedMutationDoesNotInvalidate() async {
        let store = Store<BindingTestState, BindingTestAction>(
            initialState: BindingTestState(),
            reducer: bindingTestReducer
        )

        let binding = store.binding(\.items) { .replaceItems($0) }

        let trackingFired = TrackingFlag()
        withObservationTracking {
            _ = binding.wrappedValue
        } onChange: {
            trackingFired.mark()
        }

        // Mutate the *other* property. Per-property observation means the
        // tracker registered for `items` should NOT fire.
        store.send(.replaceExtras(EntityStore([TestEntity(name: "Unrelated")])))

        await Task.yield()
        #expect(!trackingFired.fired)
    }
}
