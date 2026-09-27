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

func testReducer(
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
    func effectsDispatchFollowUp() async {
        let effectEntity = TestEntity(name: "From Effect")
        let (inserted, insertedIn) = AsyncStream<Void>.makeStream()

        func reducer(state: inout TestState, action: TestAction) -> Effect<TestAction>? {
            switch action {
            case .noOp:
                return Effect { send in
                    await send(.insert(effectEntity))
                }
            case .insert(let entity):
                state.items[entity.id] = entity
                insertedIn.yield()
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
        // Deterministic: the reducer signals when the follow-up action lands.
        var signals = inserted.makeAsyncIterator()
        await signals.next()

        #expect(store.items[effectEntity.id] == effectEntity)
    }

    @Test("re-entrant send is deferred and runs after the current cycle")
    @MainActor
    func reentrantSendDefers() {
        let e1 = TestEntity(name: "Outer")
        let e2 = TestEntity(name: "Inner")

        let holder = StoreHolder()
        var resent = false
        let spy = SpyPlugin<TestState, TestAction>(
            onWillReduce: {
                if !resent {
                    resent = true
                    holder.store?.send(.insert(e2))
                }
            }
        )
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(spy)

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer,
            plugins: plugins
        )
        holder.store = store

        store.send(.insert(e1))

        // The inner send must be deferred, then run as a full cycle — neither
        // mutation may be lost to a stale-state clobber.
        #expect(store.items[e1.id] == e1)
        #expect(store.items[e2.id] == e2)
    }

    @Test("multiple re-entrant sends run in FIFO order")
    @MainActor
    func reentrantSendsAreFIFO() {
        let id = UUID()
        let holder = StoreHolder()
        var resent = false
        let spy = SpyPlugin<TestState, TestAction>(
            onWillReduce: {
                if !resent {
                    resent = true
                    holder.store?.send(.rename(id, "first"))
                    holder.store?.send(.rename(id, "second"))
                }
            }
        )
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(spy)

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer,
            plugins: plugins
        )
        holder.store = store

        store.send(.insert(TestEntity(id: id, name: "original")))

        // Deferred renames apply after the insert, in dispatch order.
        #expect(store.items[id]?.name == "second")
    }

    @Test("re-entrant action that itself re-entrantly sends drains FIFO")
    @MainActor
    func reentrantSendDuringDrainAppendsFIFO() {
        let id = UUID()
        let holder = StoreHolder()
        var queuedFirst = false
        var queuedFollowUp = false
        let spy = SpyPlugin<TestState, TestAction>(
            onWillReduce: {
                if !queuedFirst {
                    // Re-entrant from the initial dispatch: queues a pending action.
                    queuedFirst = true
                    holder.store?.send(.rename(id, "first"))
                } else if !queuedFollowUp {
                    // Re-entrant from *draining* "first": appends mid-drain and
                    // must still run in this pass, after "first".
                    queuedFollowUp = true
                    holder.store?.send(.rename(id, "follow-up"))
                }
            }
        )
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(spy)

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: testReducer,
            plugins: plugins
        )
        holder.store = store

        store.send(.insert(TestEntity(id: id, name: "original")))

        // The mid-drain append is drained in the same pass, in FIFO order.
        #expect(queuedFollowUp)
        #expect(store.items[id]?.name == "follow-up")
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

    @Test("undo of a delete persists the restored entity, not the deletion")
    @MainActor
    func undoOfDeletePersistsRestore() async {
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

        let entity = TestEntity(name: "Keep")
        store.send(.insert(entity))
        await persistencePlugin.flush()
        await collector.reset()

        // Delete drains a pending deletion; the undo re-inserts the entity in
        // the same flush window. The restore must win — flushing both would
        // let the delete destroy the row while the entity is live in memory.
        store.send(.delete(entity.id))
        store.undo()
        await persistencePlugin.flush()

        let writes = await collector.writes
        let deletes = await collector.deletes
        #expect(writes.contains(entity))
        #expect(!deletes.contains(entity.id))
    }

    @Test("undo does not delete, or flush a deletion of, a row another device created")
    @MainActor
    func undoKeepsRemotelyInsertedRow() async {
        let collector = PersistCollector()
        let a = TestEntity(name: "a")
        let b = TestEntity(name: "created on another device")
        var initial = TestState()
        initial.items = EntityStore([a])
        let undoPlugin = UndoPlugin<TestState, TestAction>()
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(undoPlugin)
        plugins.register(
            PersistencePlugin<TestState, TestAction>(
                writers: [
                    StateWriter(keyPath: \.items) { writes, deletes in
                        await collector.record(writes: writes, deletes: deletes)
                    }
                ],
                debounce: .milliseconds(10)
            )
        )
        let store = Store(initialState: initial, reducer: testReducer, plugins: plugins, undoPlugin: undoPlugin)

        store.send(.rename(a.id, "edited"))  // snapshot = {a}
        await store.flush()
        var aEdited = a
        aEdited.name = "edited"
        // A sync tick surfaces `b`.
        store.mutate { $0.items.reconcile(with: EntityStore([aEdited, b]), preserving: [], removingMissing: true) }

        store.undo()  // the user undoes *their own* rename
        await store.flush()
        #expect(store.items[a.id]?.name == "a")
        #expect(store.items[b.id] == b, "undo removed a row the local user never touched")

        store.redo()
        await store.flush()
        #expect(store.items[a.id]?.name == "edited")
        #expect(store.items[b.id] == b)

        let deletes = await collector.deletes
        #expect(!deletes.contains(b.id), "undo or redo flushed a deletion of another device's row")
    }

    @Test("redo does not delete a row another device created after the undo")
    @MainActor
    func redoKeepsRowInsertedAfterUndo() {
        let a = TestEntity(name: "a")
        let b = TestEntity(name: "created on another device")
        var initial = TestState()
        initial.items = EntityStore([a])
        let undoPlugin = UndoPlugin<TestState, TestAction>()
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(undoPlugin)
        let store = Store(initialState: initial, reducer: testReducer, plugins: plugins, undoPlugin: undoPlugin)

        store.send(.rename(a.id, "edited"))
        store.undo()  // redo snapshot = {a: edited}, taken before `b` exists
        store.mutate { $0.items.reconcile(with: EntityStore([a, b]), preserving: [], removingMissing: true) }
        store.redo()

        #expect(store.items[a.id]?.name == "edited")
        #expect(store.items[b.id] == b)
    }

    @Test("one undo does not also revert an earlier edit to a different item")
    @MainActor
    func coalescingRunEndsAtNonUndoableAction() {
        let a = TestEntity(name: "a")
        let b = TestEntity(name: "b")
        let isRename: @Sendable (TestAction) -> Bool = { if case .rename = $0 { true } else { false } }
        let undoPlugin = UndoPlugin<TestState, TestAction>(isUndoable: isRename, coalescing: isRename)
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(undoPlugin)
        var initial = TestState()
        initial.items = EntityStore([a, b])
        let store = Store(initialState: initial, reducer: testReducer, plugins: plugins, undoPlugin: undoPlugin)

        store.send(.rename(a.id, "a2"))  // type into A's field
        store.send(.noOp)  // e.g. `.selectItem(b)` — not undoable, not coalescing
        store.send(.rename(b.id, "b2"))  // type into B's field
        store.undo()

        #expect(store.items[b.id]?.name == "b")
        #expect(store.items[a.id]?.name == "a2", "one undo also reverted the edit to A")
    }

    @Test("an UndoPlugin registered only on the host drives undo and redo")
    @MainActor
    func undoPluginIsDiscovered() {
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(UndoPlugin<TestState, TestAction>())
        let store = Store<TestState, TestAction>(initialState: TestState(), reducer: testReducer, plugins: plugins)

        let entity = TestEntity(name: "Added")
        store.send(.insert(entity))
        #expect(store.canUndo, "snapshots accumulated while canUndo stayed false")

        store.undo()
        #expect(store.items[entity.id] == nil, "undo() was a no-op")
        store.redo()
        #expect(store.items[entity.id] == entity)
    }

    @Test("core plugins registered after Store.init are still found")
    @MainActor
    func lateRegisteredPluginsAreFound() async {
        let collector = PersistCollector()
        let plugins = PluginHost<TestState, TestAction>()
        let store = Store<TestState, TestAction>(initialState: TestState(), reducer: testReducer, plugins: plugins)
        plugins.register(UndoPlugin<TestState, TestAction>())
        plugins.register(
            PersistencePlugin<TestState, TestAction>(
                writers: [
                    StateWriter(keyPath: \.items) { writes, deletes in
                        await collector.record(writes: writes, deletes: deletes)
                    }
                ],
                debounce: .seconds(30)
            )
        )

        let entity = TestEntity(name: "Late")
        store.send(.insert(entity))
        #expect(store.canUndo)

        // `mutate` drains outside the plugin lifecycle; a store that missed the
        // plugin recorded the change and scheduled nothing, so flush wrote nothing.
        let merged = TestEntity(name: "Merged")
        store.mutate { $0.items[merged.id] = merged }
        await store.flush()

        let writes = await collector.writes
        #expect(writes.contains(merged))
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

// MARK: - Platform UndoManager

/// The three ways a user reaches undo: the Edit menu and shake-to-undo drive
/// the platform `UndoManager` (`undoManager.undo()`), while an in-app button —
/// or the macOS `CommandGroup` the tutorial installs — calls `store.undo()`.
/// Whichever one they use, the other must stay in step.
@Suite("Store and the platform UndoManager")
@MainActor
struct StoreUndoManagerTests {
    private static let isRename: @Sendable (TestAction) -> Bool = { if case .rename = $0 { true } else { false } }

    private static func makeStore(
        _ entity: TestEntity,
        coalescing: Bool = false,
        isUndoable: (@Sendable (TestAction) -> Bool)? = isRename
    ) -> Store<TestState, TestAction> {
        let never: @Sendable (TestAction) -> Bool = { _ in false }
        let undoPlugin = UndoPlugin<TestState, TestAction>(
            isUndoable: isRename, coalescing: coalescing ? isRename : never)
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(undoPlugin)
        var initial = TestState()
        initial.items = EntityStore([entity])
        return Store(
            initialState: initial, reducer: testReducer, plugins: plugins, undoPlugin: undoPlugin,
            isUndoable: isUndoable)
    }

    /// Runs `body` as one UI event. With `groupsByEvent` (the default) the
    /// manager opens a group on the first registration and closes it at the end
    /// of the run loop pass, so one pass ends the event.
    private func event(_ undoManager: UndoManager, _ body: () -> Void) {
        body()
        // A run loop with nothing scheduled returns without making a pass.
        RunLoop.current.add(Timer(timeInterval: 0, repeats: false) { _ in }, forMode: .default)
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        #expect(undoManager.groupingLevel == 0)
    }

    @Test("coalesced actions register one platform undo step")
    func coalescedActionsRegisterOnce() {
        let a = TestEntity(name: "a")
        let store = Self.makeStore(a, coalescing: true)
        let undoManager = UndoManager()
        store.undoManager = undoManager

        for name in ["h", "he", "hel"] {
            event(undoManager) { store.send(.rename(a.id, name)) }
        }
        undoManager.undo()  // Edit ▸ Undo

        #expect(store.items[a.id]?.name == "a")
        #expect(!store.canUndo)
        #expect(!undoManager.canUndo, "the UndoManager still offers Undo with nothing left to undo")
    }

    @Test("an action the undo plugin doesn't snapshot registers nothing")
    func unsnapshottedActionRegistersNothing() {
        let a = TestEntity(name: "a")
        let store = Self.makeStore(a, isUndoable: { _ in true })
        let undoManager = UndoManager()
        store.undoManager = undoManager

        event(undoManager) { store.send(.noOp) }

        #expect(!store.canUndo)
        #expect(!undoManager.canUndo, "an Undo that would revert an older, unrelated step")
    }

    @Test("system Undo after an in-app undo does not redo")
    func systemUndoAfterInAppUndo() {
        let a = TestEntity(name: "a")
        let store = Self.makeStore(a)
        let undoManager = UndoManager()
        store.undoManager = undoManager

        event(undoManager) { store.send(.rename(a.id, "b")) }
        event(undoManager) { store.undo() }  // the app's Undo button
        #expect(store.items[a.id]?.name == "a")

        undoManager.undo()  // shake to undo
        #expect(store.items[a.id]?.name == "a", "system Undo re-applied the change the user just undid")
        #expect(!undoManager.canUndo)

        undoManager.redo()  // and system Redo redoes the in-app undo
        #expect(store.items[a.id]?.name == "b")
        #expect(!store.canRedo)
    }

    @Test("in-app redo after a system undo stays in step with the UndoManager")
    func inAppRedoAfterSystemUndo() {
        let a = TestEntity(name: "a")
        let store = Self.makeStore(a)
        let undoManager = UndoManager()
        store.undoManager = undoManager

        event(undoManager) { store.send(.rename(a.id, "b")) }
        undoManager.undo()
        #expect(store.items[a.id]?.name == "a")

        event(undoManager) { store.redo() }  // the app's Redo button
        #expect(store.items[a.id]?.name == "b")
        #expect(!undoManager.canRedo)

        undoManager.undo()
        #expect(store.items[a.id]?.name == "a", "system Undo reverts the in-app redo")
    }

    @Test("with the undo plugin only registered, UndoManager registration follows it")
    func undoManagerFollowsDiscoveredPlugin() {
        let a = TestEntity(name: "a")
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(UndoPlugin<TestState, TestAction>(isUndoable: Self.isRename))
        var initial = TestState()
        initial.items = EntityStore([a])
        let store = Store<TestState, TestAction>(initialState: initial, reducer: testReducer, plugins: plugins)
        let undoManager = UndoManager()
        store.undoManager = undoManager

        event(undoManager) { store.send(.noOp) }
        #expect(!undoManager.canUndo)

        event(undoManager) { store.send(.rename(a.id, "b")) }
        #expect(undoManager.canUndo, "shake and Edit-menu undo never appeared")

        undoManager.undo()
        #expect(store.items[a.id]?.name == "a")
    }

    @Test("in-app undo and redo work when the UndoManager holds none of the store's steps")
    func inAppUndoWithoutPlatformSteps() {
        let a = TestEntity(name: "a")
        let store = Self.makeStore(a)
        store.send(.rename(a.id, "b"))  // before any UndoManager was attached
        let undoManager = UndoManager()
        store.undoManager = undoManager

        event(undoManager) { store.undo() }
        #expect(store.items[a.id]?.name == "a")
        #expect(!undoManager.canUndo, "an inverse registered outside an undo is filed as a new undo")

        event(undoManager) { store.redo() }
        #expect(store.items[a.id]?.name == "b")
        #expect(!undoManager.canUndo)
    }
}

// MARK: - Store Holder

/// Lets a plugin closure reference the store that owns it (set after init).
@MainActor
private final class StoreHolder {
    var store: Store<TestState, TestAction>?
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
