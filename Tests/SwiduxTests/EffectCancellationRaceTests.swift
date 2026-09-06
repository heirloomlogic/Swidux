import Foundation
import Testing

@testable import Swidux

@Suite("Effect cancellation races")
@MainActor
struct EffectCancellationRaceTests {
    @Test("Immediate cancellation reaches an effect before it registers its key")
    func immediateCancellation() async {
        let ran = SendableBox(false)
        let store = Store<TestState, TestAction>(initialState: .init()) { _, _ in
            cancellable(id: "work") { _ in ran.value = true }
        }
        store.send(.noOp)
        store.cancel(id: "work")
        while store.hasInFlightEffects { await Task.yield() }
        #expect(!ran.value)
    }

    @Test("Declared latest-wins scopes are registered in dispatch order")
    func reversedRegistrationOrder() async {
        let oldRan = SendableBox(false)
        let newRan = SendableBox(false)
        let store = Store<TestState, TestAction>(initialState: .init()) { _, action in
            let older: Bool
            if case .noOp = action { older = true } else { older = false }
            return cancellable(id: "search", cancelInFlight: true) { _ in
                if older { oldRan.value = true } else { newRan.value = true }
            }
        }
        // Neither task can enter its scope before these synchronous launches.
        store.send(.noOp)
        store.send(.effectAction("new"))
        while store.hasInFlightEffects { await Task.yield() }
        #expect(!oldRan.value)
        #expect(newRan.value)
    }

    @Test("A cancelled operation cannot dispatch a stale successful result")
    func cancelledResultIsSuppressed() async {
        let started = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let entity = TestEntity(name: "stale")
        let store = Store<TestState, TestAction>(initialState: .init()) { state, action in
            if case .insert(let value) = action {
                state.items[value.id] = value
                return nil
            }
            return cancellable(id: "fetch") { send in
                started.continuation.yield()
                for await _ in resume.stream { break }
                await send(.insert(entity))
            }
        }
        store.send(.noOp)
        for await _ in started.stream { break }
        store.cancel(id: "fetch")
        resume.continuation.yield()
        while store.hasInFlightEffects { await Task.yield() }
        #expect(store.items.isEmpty)
    }
}

private final class CancellationReference: Hashable, @unchecked Sendable {
    static func == (lhs: CancellationReference, rhs: CancellationReference) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

extension EffectCancellationRaceTests {
    @Test("No-op cancellations do not retain IDs on unrelated raw streams")
    func noOpCancellationReleasesID() async {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let store = Store<TestState, TestAction>(initialState: .init()) { _, _ in
            Effect { _ in
                started.continuation.yield()
                for await _ in release.stream { break }
            }
        }
        store.send(.noOp)
        for await _ in started.stream { break }
        weak var released: CancellationReference?
        do {
            let id = CancellationReference()
            released = id
            store.cancel(id: id)
        }
        #expect(released == nil)
        release.continuation.yield()
        while store.hasInFlightEffects { await Task.yield() }
    }

    @Test("Completed cancellation scopes cannot cancel a later scope")
    func completedScopesAreRemoved() async throws {
        let playbackStarted = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let cancelled = SendableBox(false)
        let store = Store<TestState, TestAction>(initialState: .init()) { _, _ in
            Effect { send in
                let download: Effect<TestAction> = cancellable(id: "download") { _ in }
                try await download(send)
                let playback: Effect<TestAction> = cancellable(id: "playback") { _ in
                    playbackStarted.continuation.yield()
                    for await _ in release.stream { break }
                    cancelled.value = Task.isCancelled
                }
                try await playback(send)
            }
        }
        store.send(.noOp)
        for await _ in playbackStarted.stream { break }
        store.cancel(id: "download")
        release.continuation.yield()
        while store.hasInFlightEffects { await Task.yield() }
        #expect(!cancelled.value)
    }
}

extension EffectCancellationRaceTests {
    @Test("An outer same-key scope remains active after its nested scope ends")
    func nestedSameKeyScopeSurvives() async {
        let outerParked = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let cancelled = SendableBox(false)
        let store = Store<TestState, TestAction>(initialState: .init()) { _, _ in
            cancellable(id: "scope") { send in
                let nested: Effect<TestAction> = cancellable(id: "scope") { _ in }
                try await nested(send)
                outerParked.continuation.yield()
                for await _ in release.stream { break }
                cancelled.value = Task.isCancelled
            }
        }
        store.send(.noOp)
        for await _ in outerParked.stream { break }
        store.cancel(id: "scope")
        release.continuation.yield()
        while store.hasInFlightEffects { await Task.yield() }
        #expect(cancelled.value)
    }

    @Test("Mapping an effect preserves declared cancellation")
    func mappedMetadataIsPreserved() async {
        let ran = SendableBox(false)
        let store = Store<TestState, TestAction>(initialState: .init()) { _, _ in
            let effect: Effect<String> = cancellable(id: "mapped") { _ in ran.value = true }
            return effect.map { .effectAction($0) }
        }
        store.send(.noOp)
        store.cancel(id: "mapped")
        while store.hasInFlightEffects { await Task.yield() }
        #expect(!ran.value)
    }

    @Test("Cancellation ignores a future dynamically declared scope")
    func undeclaredWorkIsNotCancelled() async {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let ran = SendableBox(false)
        let store = Store<TestState, TestAction>(initialState: .init()) { _, _ in
            Effect { send in
                started.continuation.yield()
                for await _ in release.stream { break }
                let future: Effect<TestAction> = cancellable(id: "future") { _ in ran.value = true }
                try await future(send)
            }
        }
        store.send(.noOp)
        for await _ in started.stream { break }
        store.cancel(id: "future")
        release.continuation.yield()
        while store.hasInFlightEffects { await Task.yield() }
        #expect(ran.value)
    }
}
