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

/// Polls until `condition` holds or the cap elapses.
@MainActor
private func poll(until condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
    var waited = Duration.zero
    while !condition(), waited < timeout {
        try await Task.sleep(for: .milliseconds(5))
        waited += .milliseconds(5)
    }
}

private func mutateTestReducer(
    state: inout TestState,
    action: TestAction
) -> Effect<TestAction>? {
    switch action {
    case .insert(let entity): state.items[entity.id] = entity
    case .delete(let id): state.items[id] = nil
    case .rename(let id, let name): state.items.modify(id) { $0.name = name }
    case .noOp, .effectAction: break
    }
    return nil
}

@MainActor
private func makeStore(
    initialState: TestState = TestState(),
    persistencePlugin: PersistencePlugin<TestState, TestAction>? = nil
) -> Store<TestState, TestAction> {
    Store(
        initialState: initialState,
        reducer: mutateTestReducer,
        persistencePlugin: persistencePlugin
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
        let recorded = Recorder()
        let writer = StateWriter<TestState>(keyPath: \.items) { writes, deletions in
            await recorded.record(writes: writes.map(\.id), deletions: deletions)
        }
        let plugin = PersistencePlugin<TestState, TestAction>(
            writers: [writer], debounce: .milliseconds(10))
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
        #expect(await recorded.writes == [entity.id])
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

// MARK: - Helpers

private actor Recorder {
    var writes: [UUID] = []
    var deletions: Set<UUID> = []

    func record(writes: [UUID], deletions: Set<UUID>) {
        self.writes.append(contentsOf: writes)
        self.deletions.formUnion(deletions)
    }
}
