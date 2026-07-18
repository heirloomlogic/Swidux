//
//  EffectCancellationTests.swift
//  SwiduxTests
//
//  Verifies keyed effect cancellation: cancel(id:) targets only the matching
//  effect, cancelInFlight replaces the prior effect under an id, ids are
//  released on natural completion, the imperative Store.cancel(id:) works from
//  outside a reducer, and cancelEffects() clears the id registry.
//

import Foundation
import Synchronization
import Testing

@testable import Swidux

@Suite("Effect Cancellation")
struct EffectCancellationTests {
    /// Actions for a reducer that returns keyed effects. Ids are `String`.
    private enum CancelAction: Sendable {
        /// A `cancellable(id:)` stream that parks until cancelled.
        case startStream(String)
        /// A `cancellable(id:, cancelInFlight: true)` stream that parks until cancelled.
        case startDebounced(String)
        /// A `cancel(id:)` effect.
        case stop(String)
        /// A `cancellable(id:)` effect that completes immediately.
        case finishQuick(String)
    }

    /// Builds a store wired to signal every effect's lifecycle, alongside the
    /// streams those signals arrive on. Signals are tagged with the effect's id
    /// so callers can tell effects apart. Streams (not iterators) are returned
    /// so each test makes its own iterator in a fresh isolation region.
    @MainActor
    private static func makeHarness() -> (
        store: Store<TestState, CancelAction>,
        started: AsyncStream<String>,
        cancelled: AsyncStream<String>,
        finished: AsyncStream<String>
    ) {
        let (startedStream, started) = AsyncStream<String>.makeStream()
        let (cancelledStream, cancelled) = AsyncStream<String>.makeStream()
        let (finishedStream, finished) = AsyncStream<String>.makeStream()
        let store = Store<TestState, CancelAction>(
            initialState: TestState(),
            reducer: reducer(started: started, cancelled: cancelled, finished: finished)
        )
        return (store, startedStream, cancelledStream, finishedStream)
    }

    /// A reducer whose effects signal their lifecycle on the given streams.
    private static func reducer(
        started: AsyncStream<String>.Continuation,
        cancelled: AsyncStream<String>.Continuation,
        finished: AsyncStream<String>.Continuation
    ) -> (inout TestState, CancelAction) -> Effect<CancelAction>? {
        { _, action in
            switch action {
            case .startStream(let id):
                return cancellable(id: id) { _ in
                    await parkUntilCancelled(id: id, started: started, cancelled: cancelled)
                }
            case .startDebounced(let id):
                return cancellable(id: id, cancelInFlight: true) { _ in
                    await parkUntilCancelled(id: id, started: started, cancelled: cancelled)
                }
            case .stop(let id):
                return cancel(id: id)
            case .finishQuick(let id):
                return cancellable(id: id) { _ in finished.yield(id) }
            }
        }
    }

    /// Signals `started`, parks until the task is cancelled, then signals `cancelled`.
    private static func parkUntilCancelled(
        id: String,
        started: AsyncStream<String>.Continuation,
        cancelled: AsyncStream<String>.Continuation
    ) async {
        await withTaskCancellationHandler {
            started.yield(id)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
        } onCancel: {
            cancelled.yield(id)
        }
    }

    /// Pulls `count` values off an iterator, in arrival order.
    private static func drain(
        _ iterator: inout AsyncStream<String>.AsyncIterator,
        count: Int
    ) async -> [String] {
        var values: [String] = []
        for _ in 0..<count {
            guard let value = await iterator.next() else { break }
            values.append(value)
        }
        return values
    }

    @Test("cancel(id:) cancels only the matching effect")
    @MainActor
    func cancelTargetsOneEffect() async {
        let (store, startedStream, cancelledStream, _) = Self.makeHarness()
        var started = startedStream.makeAsyncIterator()
        var cancelled = cancelledStream.makeAsyncIterator()

        store.send(.startStream("a"))
        store.send(.startStream("b"))
        // Both effects register before they signal `started`, so once both have
        // started, both are cancellable. Order between them is unspecified.
        #expect(Set(await Self.drain(&started, count: 2)) == ["a", "b"])

        store.send(.stop("a"))
        #expect(await cancelled.next() == "a")
        #expect(store.hasInFlightEffects)  // "b" is untouched.

        store.send(.stop("b"))
        #expect(await cancelled.next() == "b")
        while store.hasInFlightEffects { await Task.yield() }
        #expect(!store.hasInFlightEffects)
    }

    @Test("cancelInFlight replaces the prior effect under the same id")
    @MainActor
    func cancelInFlightReplaces() async {
        let (store, startedStream, cancelledStream, _) = Self.makeHarness()
        var started = startedStream.makeAsyncIterator()
        var cancelled = cancelledStream.makeAsyncIterator()

        store.send(.startDebounced("s"))
        #expect(await started.next() == "s")  // first registered + running

        store.send(.startDebounced("s"))  // cancels the first, starts the second
        #expect(await cancelled.next() == "s")  // first was cancelled
        #expect(await started.next() == "s")  // second is running
        #expect(store.hasInFlightEffects)
    }

    @Test("an effect's id is released when it completes normally")
    @MainActor
    func idReleasedOnCompletion() async {
        let (store, startedStream, cancelledStream, finishedStream) = Self.makeHarness()
        var started = startedStream.makeAsyncIterator()
        var cancelled = cancelledStream.makeAsyncIterator()
        var finished = finishedStream.makeAsyncIterator()

        // An effect that finishes on its own frees its id.
        store.send(.finishQuick("q"))
        #expect(await finished.next() == "q")
        while store.hasInFlightEffects { await Task.yield() }

        // Cancelling the now-freed id is a harmless no-op.
        store.send(.stop("q"))

        // The id can be reused cleanly by a later effect.
        store.send(.startStream("q"))
        #expect(await started.next() == "q")
        store.send(.stop("q"))
        #expect(await cancelled.next() == "q")
    }

    @Test("Store.cancel(id:) cancels from outside a reducer")
    @MainActor
    func imperativeCancel() async {
        let (store, startedStream, cancelledStream, _) = Self.makeHarness()
        var started = startedStream.makeAsyncIterator()
        var cancelled = cancelledStream.makeAsyncIterator()

        store.send(.startStream("x"))
        #expect(await started.next() == "x")

        store.cancel(id: "x")  // imperative, e.g. from .onDisappear
        #expect(await cancelled.next() == "x")
        while store.hasInFlightEffects { await Task.yield() }
        #expect(!store.hasInFlightEffects)
    }

    @Test("cancelEffects() clears the registry; the store stays usable")
    @MainActor
    func cancelEffectsClearsRegistry() async {
        let (store, startedStream, cancelledStream, _) = Self.makeHarness()
        var started = startedStream.makeAsyncIterator()
        var cancelled = cancelledStream.makeAsyncIterator()

        store.send(.startStream("y"))
        #expect(await started.next() == "y")

        store.cancelEffects()
        #expect(await cancelled.next() == "y")
        #expect(!store.hasInFlightEffects)

        // The same id works again afterwards — the registry was cleared.
        store.send(.startStream("y"))
        #expect(await started.next() == "y")
        store.cancel(id: "y")
        #expect(await cancelled.next() == "y")
    }

    @Test("cancellable outside a store simply runs the operation")
    func cancellableWithoutStoreRuns() async throws {
        let ran = Mutex(false)
        let effect: Effect<CancelAction> = cancellable(id: "z") { _ in
            ran.withLock { $0 = true }
        }
        // No task-local context is bound, so it just runs.
        try await effect { _ in }
        #expect(ran.withLock { $0 })
    }
}
