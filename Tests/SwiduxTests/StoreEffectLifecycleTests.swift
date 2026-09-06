//
//  StoreEffectLifecycleTests.swift
//  SwiduxTests
//
//  Verifies the store's effect-task registry: self-removal on completion,
//  cancellation on deinit and cancelEffects(), and throwing-effect containment.
//

import Foundation
import Testing

@testable import Swidux

@Suite("Store Effect Lifecycle")
struct StoreEffectLifecycleTests {
    /// Reducer whose `.noOp` returns a streaming effect that parks until
    /// cancelled, signalling `started` once running and `cancelled` on cancel.
    private static func streamingReducer(
        started: AsyncStream<Void>.Continuation,
        cancelled: AsyncStream<Void>.Continuation
    ) -> (inout TestState, TestAction) -> Effect<TestAction>? {
        { state, action in
            switch action {
            case .noOp:
                return Effect { _ in
                    await withTaskCancellationHandler {
                        started.yield()
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                    } onCancel: {
                        cancelled.yield()
                    }
                }
            case .insert(let entity):
                state.items[entity.id] = entity
                return nil
            default:
                return nil
            }
        }
    }

    @Test("deinit cancels in-flight streaming effects")
    @MainActor
    func deinitCancelsEffects() async {
        let (startedStream, started) = AsyncStream<Void>.makeStream()
        let (cancelledStream, cancelled) = AsyncStream<Void>.makeStream()

        var store: Store<TestState, TestAction>? = Store(
            initialState: TestState(),
            reducer: Self.streamingReducer(started: started, cancelled: cancelled)
        )
        store?.send(.noOp)

        var startedSignals = startedStream.makeAsyncIterator()
        await startedSignals.next()

        store = nil

        // Reaching the cancellation signal is the assertion: without deinit
        // cancellation the streaming effect parks forever and the test times out.
        var cancelledSignals = cancelledStream.makeAsyncIterator()
        await cancelledSignals.next()
    }

    @Test("cancelEffects stops a streaming effect while the store lives")
    @MainActor
    func cancelEffectsStopsStream() async {
        let (startedStream, started) = AsyncStream<Void>.makeStream()
        let (cancelledStream, cancelled) = AsyncStream<Void>.makeStream()

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: Self.streamingReducer(started: started, cancelled: cancelled)
        )
        store.send(.noOp)

        var startedSignals = startedStream.makeAsyncIterator()
        await startedSignals.next()
        #expect(store.hasInFlightEffects)

        store.cancelEffects()

        var cancelledSignals = cancelledStream.makeAsyncIterator()
        await cancelledSignals.next()
        #expect(!store.hasInFlightEffects)

        // The store remains fully usable afterwards.
        let entity = TestEntity(name: "After cancel")
        store.send(.insert(entity))
        #expect(store.items[entity.id] == entity)
    }

    @Test("a cancelled effect can still dispatch from its catch block")
    @MainActor
    func cancelledEffectCanStillSend() async throws {
        let marker = TestEntity(name: "cleanup")
        let (startedStream, started) = AsyncStream<Void>.makeStream()

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: { state, action in
                switch action {
                case .noOp:
                    return Effect { send in
                        started.yield()
                        do {
                            try await Task.sleep(for: .seconds(60))
                        } catch {
                            // The cleanup path every plugin's async effect
                            // relies on to clear its own in-flight flag.
                            await send(.insert(marker))
                            throw error
                        }
                    }
                case .insert(let entity):
                    state.items[entity.id] = entity
                    return nil
                default:
                    return nil
                }
            }
        )
        store.send(.noOp)
        var startedSignals = startedStream.makeAsyncIterator()
        await startedSignals.next()

        store.cancelEffects()

        // Cancellation stops the *sleep*; hopping to the main actor to dispatch
        // afterwards is not itself cancellable. This is why a plugin that sets
        // an `isFetching`-style flag and clears it in `catch` does not strand
        // the flag on teardown — pinned here because the alternative is a
        // spinner that never stops, and nothing else would notice.
        try await poll(until: { store.items[marker.id] != nil })
        #expect(store.items[marker.id] == marker)
    }

    @Test("completed effects remove themselves from the registry")
    @MainActor
    func completedEffectsSelfRemove() async {
        let (finishedStream, finished) = AsyncStream<Void>.makeStream()

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: { _, action in
                guard case .noOp = action else { return nil }
                return Effect { _ in finished.yield() }
            }
        )
        store.send(.noOp)

        var finishedSignals = finishedStream.makeAsyncIterator()
        await finishedSignals.next()

        // The registry entry is removed on a MainActor hop right after the
        // effect body returns; yield until it lands.
        while store.hasInFlightEffects {
            await Task.yield()
        }
        #expect(!store.hasInFlightEffects)
    }

    @Test("throwing effect is contained; store keeps dispatching")
    @MainActor
    func throwingEffectContained() async {
        struct EffectError: Error {}
        let (ranStream, ran) = AsyncStream<Void>.makeStream()

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: { state, action in
                switch action {
                case .noOp:
                    return Effect { _ in
                        ran.yield()
                        throw EffectError()
                    }
                case .insert(let entity):
                    state.items[entity.id] = entity
                    return nil
                default:
                    return nil
                }
            }
        )
        store.send(.noOp)

        var ranSignals = ranStream.makeAsyncIterator()
        await ranSignals.next()
        while store.hasInFlightEffects {
            await Task.yield()
        }

        // The error is logged, not propagated — dispatch keeps working.
        let entity = TestEntity(name: "Still alive")
        store.send(.insert(entity))
        #expect(store.items[entity.id] == entity)
        #expect(!store.hasInFlightEffects)
    }
}
