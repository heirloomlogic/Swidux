//
//  StoreTests.swift
//  SwiduxTests
//
//  Tests for the generic Store with SwiduxObservable.
//

import Foundation
import Testing

@testable import Swidux

// MARK: - Test Observer

@Observable
@MainActor
final class TestStateObserver {
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

// MARK: - SwiduxObservable Conformance

extension TestState: SwiduxObservable {
    typealias Observer = TestStateObserver

    @MainActor
    init(observer: TestStateObserver) {
        self.items = observer.items
        self.extras = observer.extras
    }

    @MainActor
    static func makeObserver(from state: TestState) -> TestStateObserver {
        TestStateObserver(items: state.items, extras: state.extras)
    }

    @MainActor
    static func apply(_ snapshot: TestState, to observer: TestStateObserver) {
        observer.items = snapshot.items
        observer.extras = snapshot.extras
    }

    @MainActor
    static func applyRestore(from snapshot: TestState, to current: inout TestState) {
        current.items.restore(from: snapshot.items)
        current.extras.restore(from: snapshot.extras)
    }
}

// MARK: - Test Reducer

private func testReducer(
    state: inout TestState,
    action: TestAction
) -> Effect<TestAction>? {
    switch action {
    case .insert(let entity):
        state.items[entity.id] = entity
    case .delete(let id):
        state.items[id] = nil
    case .rename(let id, let name):
        state.items.modify(id) { $0.name = name }
    case .noOp:
        break
    case .effectAction:
        break
    }
    return nil
}

// MARK: - Tests

@Suite("Store")
struct StoreTests {
    @Test("send dispatches action and updates observer")
    @MainActor
    func sendUpdatesObserver() {
        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer
        )

        let entity = TestEntity(name: "Hello")
        store.send(.insert(entity))

        #expect(store.observer.items[entity.id] == entity)
    }

    @Test("dynamicMemberLookup forwards to observer")
    @MainActor
    func dynamicMemberLookup() {
        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer
        )

        let entity = TestEntity(name: "Test")
        store.send(.insert(entity))

        #expect(store.items[entity.id] == entity)
        #expect(store.items.count == 1)
    }

    @Test("noOp action does not change state")
    @MainActor
    func noOpDoesNotChange() {
        let entity = TestEntity(name: "Existing")
        var initial = TestState()
        initial.items[entity.id] = entity

        let store = Store<TestState, TestAction>(
            initialState: initial,
            reducer: testReducer
        )

        store.send(.noOp)
        #expect(store.items.count == 1)
        #expect(store.items[entity.id]?.name == "Existing")
    }

    @Test("plugins receive lifecycle callbacks")
    @MainActor
    func pluginLifecycle() {
        var willReduceCalled = false
        var reduceCalled = false
        var afterReduceCalled = false

        let spy = SpyPlugin<TestState, TestAction>(
            onWillReduce: { willReduceCalled = true },
            onReduce: { reduceCalled = true },
            onAfterReduce: { afterReduceCalled = true }
        )

        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(spy)

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer,
            plugins: plugins
        )

        store.send(.noOp)

        #expect(willReduceCalled)
        #expect(reduceCalled)
        #expect(afterReduceCalled)
    }

    @Test("effects dispatch follow-up actions")
    @MainActor
    func effectsDispatchFollowUp() async throws {
        let effectEntity = TestEntity(name: "From Effect")

        func reducer(state: inout TestState, action: TestAction) -> Effect<TestAction>? {
            switch action {
            case .noOp:
                return { send in
                    await send(.insert(effectEntity))
                }
            case .insert(let entity):
                state.items[entity.id] = entity
                return nil
            default:
                return nil
            }
        }

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: reducer
        )

        store.send(.noOp)
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.items[effectEntity.id] == effectEntity)
    }

    @Test("undo restores previous state")
    @MainActor
    func undoRestores() {
        let undoPlugin = UndoPlugin<TestState, TestAction>()
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(undoPlugin)

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer,
            plugins: plugins,
            undoPlugin: undoPlugin,
            isUndoable: { _ in true }
        )

        let entity = TestEntity(name: "Added")
        store.send(.insert(entity))
        #expect(store.items.count == 1)
        #expect(store.canUndo)

        store.undo()
        #expect(store.items.count == 0)
        #expect(store.canRedo)
    }

    @Test("redo re-applies undone state")
    @MainActor
    func redoReapplies() {
        let undoPlugin = UndoPlugin<TestState, TestAction>()
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(undoPlugin)

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer,
            plugins: plugins,
            undoPlugin: undoPlugin,
            isUndoable: { _ in true }
        )

        let entity = TestEntity(name: "Added")
        store.send(.insert(entity))
        store.undo()
        #expect(store.items.count == 0)

        store.redo()
        #expect(store.items.count == 1)
        #expect(store.items[entity.id]?.name == "Added")
    }

    @Test("undo records changes for persistence")
    @MainActor
    func undoRecordsChanges() async throws {
        let collector = PersistCollector()

        let persistencePlugin = PersistencePlugin<TestState, TestAction>(
            writers: [
                StateWriter(keyPath: \.items) { writes, deletes in
                    await collector.record(writes: writes, deletes: deletes)
                }
            ],
            debounce: .milliseconds(20)
        )

        let undoPlugin = UndoPlugin<TestState, TestAction>()
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(undoPlugin)
        plugins.register(persistencePlugin)

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer,
            plugins: plugins,
            undoPlugin: undoPlugin,
            persistencePlugin: persistencePlugin,
            isUndoable: { _ in true }
        )

        let entity = TestEntity(name: "Tracked")
        store.send(.insert(entity))
        await persistencePlugin.flush()

        await collector.reset()

        store.undo()
        await persistencePlugin.flush()

        let deletes = await collector.deletes
        #expect(deletes.contains(entity.id))
    }

    @Test("multiple send calls accumulate state")
    @MainActor
    func multipleSends() {
        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer
        )

        let e1 = TestEntity(name: "One")
        let e2 = TestEntity(name: "Two")
        let e3 = TestEntity(name: "Three")

        store.send(.insert(e1))
        store.send(.insert(e2))
        store.send(.insert(e3))

        #expect(store.items.count == 3)
    }

    @Test("canUndo and canRedo update after each operation")
    @MainActor
    func undoRedoFlags() {
        let undoPlugin = UndoPlugin<TestState, TestAction>()
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(undoPlugin)

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer,
            plugins: plugins,
            undoPlugin: undoPlugin,
            isUndoable: { action in
                if case .noOp = action { return false }
                return true
            }
        )

        #expect(!store.canUndo)
        #expect(!store.canRedo)

        store.send(.insert(TestEntity(name: "A")))
        #expect(store.canUndo)
        #expect(!store.canRedo)

        store.undo()
        #expect(!store.canUndo)
        #expect(store.canRedo)

        store.redo()
        #expect(store.canUndo)
        #expect(!store.canRedo)
    }
}

// MARK: - Persist Collector

private actor PersistCollector {
    var writes: [TestEntity] = []
    var deletes: Set<UUID> = []

    func record(writes: [TestEntity], deletes: Set<UUID>) {
        self.writes.append(contentsOf: writes)
        self.deletes.formUnion(deletes)
    }

    func reset() {
        writes.removeAll()
        deletes.removeAll()
    }
}

// MARK: - Spy Plugin

@MainActor
private final class SpyPlugin<State, Action>: SwiduxPlugin {
    let onWillReduce: () -> Void
    let onReduce: () -> Void
    let onAfterReduce: () -> Void

    init(
        onWillReduce: @escaping () -> Void = {},
        onReduce: @escaping () -> Void = {},
        onAfterReduce: @escaping () -> Void = {}
    ) {
        self.onWillReduce = onWillReduce
        self.onReduce = onReduce
        self.onAfterReduce = onAfterReduce
    }

    func willReduce(state: State, action: Action) {
        onWillReduce()
    }

    func reduce(state: inout State, action: Action) -> Effect<Action>? {
        onReduce()
        return nil
    }

    func afterReduce(state: inout State, action: Action) {
        onAfterReduce()
    }
}
