//
//  StoreMutateTests.swift
//  SwiduxTests
//
//  `Store.mutate(awaiting:merging:)` — the supported way to fold the result of
//  an `await` into a live store without losing whatever was dispatched while
//  the await was in flight.
//

import Foundation
import Testing

@testable import Swidux

// MARK: - Gate

/// Parks a caller until `open()` is called, so a test can interleave a dispatch
/// at an exact point rather than racing a sleep against CI scheduling.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func makeStore(
    initialState: TestState = TestState(),
    persistencePlugin: PersistencePlugin<TestState, TestAction>? = nil
) -> Store<TestState, TestAction> {
    Store(
        initialState: initialState,
        reducer: testReducer,
        persistencePlugin: persistencePlugin
    )
}

/// Records what each flush carried, behind a plugin with a short debounce.
///
/// Deletions are recorded alongside writes because undo restores a *diff*: the
/// step that proves a restore was drained is a deletion, and a recorder that
/// only watched writes would pass on an empty flush.
@MainActor
private func makeRecordingPlugin() -> (
    plugin: PersistencePlugin<TestState, TestAction>,
    writes: SendableBox<[UUID]>,
    deletions: SendableBox<[UUID]>
) {
    let writes = SendableBox<[UUID]>([])
    let deletions = SendableBox<[UUID]>([])
    let writer = StateWriter<TestState>(keyPath: \.items) { written, deleted in
        writes.value.append(contentsOf: written.map(\.id))
        deletions.value.append(contentsOf: deleted)
    }
    return (
        PersistencePlugin<TestState, TestAction>(writers: [writer], debounce: .milliseconds(10)),
        writes,
        deletions
    )
}

// MARK: - Tests

@Suite("Store.mutate")
@MainActor
struct StoreMutateTests {
    @Test("a dispatch landing during the awaited phase survives the merge")
    func concurrentDispatchSurvives() async throws {
        let store = makeStore()
        let gate = Gate()
        let merged = TestEntity(name: "from await")
        let live = TestEntity(name: "dispatched mid-await")

        let task = Task {
            await store.mutate {
                await gate.wait()
                return merged
            } merging: { entity, state in
                state.items[entity.id] = entity
            }
        }

        try await poll(until: { gate.isWaiting })
        store.send(.insert(live))
        gate.open()
        await task.value

        #expect(store.items[live.id] == live, "the concurrent dispatch must not be clobbered")
        #expect(store.items[merged.id] == merged)
        #expect(store.items.count == 2)
    }

    @Test("the hand-rolled pack/await/unpack idiom loses that dispatch — why mutate exists")
    func handRolledIdiomLosesTheDispatch() async throws {
        let store = makeStore()
        let gate = Gate()
        let live = TestEntity(name: "dispatched mid-await")

        let task = Task { @MainActor in
            // The broken shape: snapshot packed BEFORE the await.
            var snapshot = TestState(observer: store.observer)
            await gate.wait()
            snapshot.items[TestEntity(name: "from await").id] = TestEntity(name: "from await")
            TestState.apply(snapshot, to: store.observer)
        }

        try await poll(until: { gate.isWaiting })
        store.send(.insert(live))
        gate.open()
        await task.value

        // Pinned deliberately: this is the bug `mutate` prevents. If a future
        // change closes it elsewhere, this test fails and points here.
        #expect(store.items[live.id] == nil, "the stale snapshot overwrites the concurrent dispatch")
    }

    @Test("entity writes made while merging are drained and scheduled for persistence")
    func mergedWritesAreScheduledForFlush() async throws {
        let (plugin, recorded, _) = makeRecordingPlugin()
        let store = makeStore(persistencePlugin: plugin)
        let entity = TestEntity(name: "merged")

        await store.mutate {
            entity
        } merging: { entity, state in
            state.items[entity.id] = entity
        }
        await plugin.flush()

        // No intervening `send` — without the drain inside `mutate`, this write
        // would sit in the store unflushed until the next dispatch.
        #expect(recorded.value == [entity.id])
    }

    @Test("a plugin registered on the host alone is still drained by mutate")
    func registeredPluginIsFoundWithoutTheParameter() async throws {
        let (plugin, recorded, _) = makeRecordingPlugin()
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(plugin)
        // Registered and *not* passed as `persistencePlugin:` — the wiring
        // <doc:HowToAddPersistence> shows. Two ways to say one thing is a
        // footgun: the write below reaches disk only on the next dispatch when
        // the store can't find the plugin, so an app that folds an API result in
        // with `mutate` and then terminates loses it.
        let store = Store(initialState: TestState(), reducer: testReducer, plugins: plugins)
        let entity = TestEntity(name: "merged")

        store.mutate { $0.items[entity.id] = entity }
        await plugin.flush()

        #expect(recorded.value == [entity.id])
    }

    @Test("undo/redo writes are drained through a host-registered plugin too")
    func undoDrainsThroughTheRegisteredPlugin() async throws {
        let (plugin, writes, deletions) = makeRecordingPlugin()
        let undo = UndoPlugin<TestState, TestAction>()
        let plugins = PluginHost<TestState, TestAction>()
        plugins.register(undo)
        plugins.register(plugin)
        let store = Store(
            initialState: TestState(), reducer: testReducer, plugins: plugins, undoPlugin: undo)
        let entity = TestEntity(name: "undone")

        store.send(.insert(entity))
        await plugin.flush()
        #expect(writes.value == [entity.id])

        store.undo()
        await plugin.flush()

        // Undoing the insert leaves a deletion to persist. Reaching the writer
        // is the assertion: with no plugin to drain through it would sit in the
        // `EntityStore`'s changelog, and the row would survive on disk.
        #expect(store.items[entity.id] == nil)
        #expect(deletions.value == [entity.id])
    }

    @Test("a send from inside merging is deferred, then runs after the merge commits")
    func reentrantSendIsDeferred() async throws {
        let store = makeStore()
        let merged = TestEntity(name: "merged")
        let reentrant = TestEntity(name: "reentrant")

        await store.mutate {
            merged
        } merging: { entity, state in
            state.items[entity.id] = entity
            // Re-entrant: `mutate` holds `isDispatching`, so this is queued
            // rather than packing a pre-merge snapshot and clobbering us.
            store.send(.insert(reentrant))
        }

        #expect(store.items[merged.id] == merged)
        #expect(store.items[reentrant.id] == reentrant)
    }

    @Test("the synchronous mutate folds in and schedules persistence without an await")
    func synchronousMutate() async throws {
        let recorded = SendableBox<[UUID]>([])
        let writer = StateWriter<TestState>(keyPath: \.items) { writes, _ in
            recorded.value.append(contentsOf: writes.map(\.id))
        }
        let plugin = PersistencePlugin<TestState, TestAction>(
            writers: [writer], debounce: .milliseconds(10))
        let store = makeStore(persistencePlugin: plugin)
        let entity = TestEntity(name: "folded")

        store.mutate { $0.items[entity.id] = entity }
        await plugin.flush()

        #expect(store.items[entity.id] == entity)
        #expect(recorded.value == [entity.id])
    }

    @Test("mutate rethrows and leaves state untouched when produce throws")
    func rethrowsLeavingStateUntouched() async throws {
        struct Boom: Error {}
        let existing = TestEntity(name: "existing")
        var initial = TestState()
        initial.items[existing.id] = existing
        initial.items.resetChanges()
        let store = makeStore(initialState: initial)

        await #expect(throws: Boom.self) {
            try await store.mutate {
                throw Boom()
            } merging: { (_: Never, state: inout TestState) in
                Issue.record("merging must not run when produce throws")
            }
        }

        #expect(store.items.values == [existing])
    }
}
