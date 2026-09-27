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

// MARK: - Reporting cancellation

/// A keyed scope's sends are dropped once it is cancelled — that is what keeps
/// a stale result out — so its `catch` block can't report the cancellation the
/// way a plain effect's can. `onCancel:` is how it reports instead.
extension EffectCancellationRaceTests {
    /// A store whose `.noOp` starts a keyed search that parks until cancelled,
    /// and whose `.effectAction` appends to `log`.
    private func makeSearchStore(
        log: SendableBox<[String]>,
        started: AsyncStream<Void>.Continuation,
        cancelInFlight: Bool = false
    ) -> Store<TestState, TestAction> {
        Store<TestState, TestAction>(initialState: .init()) { _, action in
            switch action {
            case .noOp:
                return cancellable(id: "search", cancelInFlight: cancelInFlight, onCancel: .effectAction("cancelled")) {
                    send in
                    started.yield()
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        await send(.effectAction("caught"))  // stale by construction: dropped
                        throw error
                    }
                }
            case .delete:
                return cancel(id: "search")
            case .effectAction(let entry):
                log.value.append(entry)
                return nil
            default:
                return nil
            }
        }
    }

    @Test("Store.cancel(id:) from view code dispatches the scope's onCancel")
    func imperativeCancelReports() async {
        let log = SendableBox<[String]>([])
        let (startedStream, started) = AsyncStream<Void>.makeStream()
        let store = makeSearchStore(log: log, started: started)
        store.send(.noOp)
        for await _ in startedStream { break }

        store.cancel(id: "search")  // `.onDisappear`, where no reducer runs

        #expect(log.value == ["cancelled"], "the in-flight flag would stay set forever")
        while store.hasInFlightEffects { await Task.yield() }
        #expect(log.value == ["cancelled"], "the catch-block send is still suppressed")
    }

    @Test("A cancel(id:) effect dispatches onCancel after the action that returned it")
    func cancelEffectReports() async {
        let log = SendableBox<[String]>([])
        let (startedStream, started) = AsyncStream<Void>.makeStream()
        let store = makeSearchStore(log: log, started: started)
        store.send(.noOp)
        for await _ in startedStream { break }

        store.send(.delete(UUID()))

        #expect(log.value == ["cancelled"])
    }

    @Test("cancelEffects() dispatches onCancel; the store stays usable")
    func cancelEffectsReports() async {
        let log = SendableBox<[String]>([])
        let (startedStream, started) = AsyncStream<Void>.makeStream()
        let store = makeSearchStore(log: log, started: started)
        store.send(.noOp)
        for await _ in startedStream { break }

        store.cancelEffects()

        #expect(log.value == ["cancelled"])
    }

    @Test("A cancelInFlight replacement does not dispatch the replaced scope's onCancel")
    func replacementDoesNotReport() async {
        let log = SendableBox<[String]>([])
        let (startedStream, started) = AsyncStream<Void>.makeStream()
        let store = makeSearchStore(log: log, started: started, cancelInFlight: true)
        var starts = startedStream.makeAsyncIterator()
        store.send(.noOp)
        await starts.next()

        store.send(.noOp)  // the new search is still in flight; its reducer owns the flag
        await starts.next()
        #expect(log.value.isEmpty)

        store.cancel(id: "search")
        #expect(log.value == ["cancelled"], "reported once, for the scope actually cancelled")
    }

    @Test("onCancel is dispatched once, and not for a scope that already finished")
    func onCancelOnlyForLiveScopes() async {
        let log = SendableBox<[String]>([])
        let (startedStream, started) = AsyncStream<Void>.makeStream()
        let store = makeSearchStore(log: log, started: started)
        store.send(.noOp)
        for await _ in startedStream { break }

        store.cancel(id: "search")
        store.cancel(id: "search")
        #expect(log.value == ["cancelled"])

        while store.hasInFlightEffects { await Task.yield() }
        store.cancel(id: "search")
        #expect(log.value == ["cancelled"])
    }

    @Test("Mapping an effect preserves onCancel")
    func mappedOnCancelIsPreserved() async {
        let log = SendableBox<[String]>([])
        let (startedStream, started) = AsyncStream<Void>.makeStream()
        let store = Store<TestState, TestAction>(initialState: .init()) { _, action in
            switch action {
            case .noOp:
                let effect: Effect<String> = cancellable(id: "mapped", onCancel: "cancelled") { _ in
                    started.yield()
                    try await Task.sleep(for: .seconds(60))
                }
                return effect.map { .effectAction($0) }
            case .effectAction(let entry):
                log.value.append(entry)
                return nil
            default:
                return nil
            }
        }
        store.send(.noOp)
        for await _ in startedStream { break }

        store.cancel(id: "mapped")

        #expect(log.value == ["cancelled"])
    }
}
