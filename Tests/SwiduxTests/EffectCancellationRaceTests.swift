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

// MARK: - Nested scopes

/// A scope invoked inside another effect is its own cancellable unit: cancelling
/// its id cancels it, not the effect hosting it or that effect's other scopes.
extension EffectCancellationRaceTests {
    /// A store that appends every `.effectAction` to `log` and runs `effect` on `.noOp`.
    private func makeHostStore(
        log: SendableBox<[String]>,
        effect: @escaping @Sendable () -> Effect<TestAction>
    ) -> Store<TestState, TestAction> {
        Store<TestState, TestAction>(initialState: .init()) { _, action in
            switch action {
            case .noOp:
                return effect()
            case .effectAction(let entry):
                log.value.append(entry)
                return nil
            default:
                return nil
            }
        }
    }

    @Test("Cancelling a nested scope does not end the effect hosting it")
    func nestedCancelSparesHost() async throws {
        let (events, feed) = AsyncStream<Int>.makeStream()
        let fetchStarted = AsyncStream<Void>.makeStream()
        let log = SendableBox<[String]>([])
        let store = makeHostStore(log: log) {
            Effect { send in
                for await value in events {
                    let fetch: Effect<TestAction> = cancellable(
                        id: "fetch", cancelInFlight: true, onCancel: .effectAction("fetch \(value) cancelled")
                    ) { send in
                        fetchStarted.continuation.yield()
                        try await Task.sleep(for: .milliseconds(value == 1 ? 60_000 : 1))
                        await send(.effectAction("fetched \(value)"))
                    }
                    try? await fetch(send)
                }
            }
        }
        store.send(.noOp)
        feed.yield(1)
        for await _ in fetchStarted.stream { break }

        store.cancel(id: "fetch")  // abandon only the slow fetch
        #expect(log.value == ["fetch 1 cancelled"])

        feed.yield(2)  // the listener keeps handling events
        try await poll(until: { log.value.contains("fetched 2") })
        #expect(log.value == ["fetch 1 cancelled", "fetched 2"], "the listener died with its nested fetch")
        store.cancelEffects()
    }

    @Test("Cancelling a nested scope leaves a sibling scope in the same effect running")
    func nestedCancelSparesSibling() async throws {
        let started = AsyncStream<String>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let siblingCancelled = SendableBox<Bool?>(nil)
        let log = SendableBox<[String]>([])
        let store = makeHostStore(log: log) {
            Effect { send in
                let slow: Effect<TestAction> = cancellable(id: "slow") { _ in
                    started.continuation.yield("slow")
                    try await Task.sleep(for: .seconds(60))
                }
                let sibling: Effect<TestAction> = cancellable(id: "sibling") { send in
                    started.continuation.yield("sibling")
                    for await _ in release.stream { break }
                    siblingCancelled.value = Task.isCancelled
                    await send(.effectAction("sibling done"))
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { try? await slow(send) }
                    group.addTask { try? await sibling(send) }
                }
            }
        }
        store.send(.noOp)
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        _ = await starts.next()

        store.cancel(id: "slow")
        release.continuation.yield()
        try await poll(until: { siblingCancelled.value != nil })

        #expect(siblingCancelled.value == false, "distinct ids are independent")
        #expect(log.value == ["sibling done"])
        store.cancelEffects()
    }

    @Test("cancelInFlight replaces a concurrent nested scope in the same effect")
    func nestedCancelInFlightDedupesSiblings() async throws {
        let firstStarted = AsyncStream<Void>.makeStream()
        let log = SendableBox<[String]>([])
        let store = makeHostStore(log: log) {
            Effect { send in
                let first: Effect<TestAction> = cancellable(id: "latest", cancelInFlight: true) { send in
                    firstStarted.continuation.yield()
                    try await Task.sleep(for: .seconds(60))
                    await send(.effectAction("stale"))
                }
                let second: Effect<TestAction> = cancellable(id: "latest", cancelInFlight: true) { send in
                    await send(.effectAction("latest"))
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { try? await first(send) }
                    for await _ in firstStarted.stream { break }
                    group.addTask { try? await second(send) }
                }
                await send(.effectAction("host done"))
            }
        }
        store.send(.noOp)

        try await poll(until: { log.value.contains("host done") })
        #expect(log.value == ["latest", "host done"], "the first scope was never replaced")
        store.cancelEffects()
    }

    @Test("A nested cancelInFlight scope does not cancel the scope enclosing it")
    func nestedCancelInFlightSparesEnclosingScope() async throws {
        let log = SendableBox<[String]>([])
        let store = makeHostStore(log: log) {
            cancellable(id: "scope") { send in
                let inner: Effect<TestAction> = cancellable(id: "scope", cancelInFlight: true) { _ in }
                try await inner(send)
                await send(.effectAction("outer survived"))
            }
        }
        store.send(.noOp)

        try await poll(until: { !store.hasInFlightEffects })
        #expect(log.value == ["outer survived"])
    }
}
