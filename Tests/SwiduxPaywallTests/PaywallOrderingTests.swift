import Swidux
import Testing

@testable import SwiduxPaywall

@Suite("Paywall result ordering")
struct PaywallOrderingTests {
    @Test("independent shared-service reads supersede a plugin refresh only on success", arguments: [false, true])
    @MainActor
    func independentReadDoesNotStrandRefresh(newerSucceeds: Bool) async throws {
        let store = InMemoryKeyValueStore()
        let base = ConcurrentPaywallService()
        let service = ResilientPaywallService(base: base, store: store, maxAttempts: 1)
        let plugin = makePlugin(service: service)
        var state = TestState()
        let refresh = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let read = Task { try await collectActions(from: refresh) }
        await base.waitForReads(1)

        let independent = Task { try? await service.customerInfo() }
        await base.waitForReads(2)
        await base.finishRead(2, fails: !newerSucceeds, snapshot: .init())
        _ = await independent.value
        await base.finishRead(1, snapshot: .init(isPro: true))
        for action in try await read.value {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(!state.paywall.isLoading)
        #expect(state.paywall.isPro == !newerSucceeds)
        #expect(state.paywall.error == nil)
        #expect(store.value(.lastKnownEntitlement)?.isPro == !newerSucceeds)
    }

    @Test("provider cancellation completes a current refresh instead of stranding loading")
    @MainActor
    func providerCancellationCompletesRefresh() async throws {
        let base = ConcurrentPaywallService()
        let plugin = makePlugin(service: base)
        var state = TestState()
        let effect = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let read = Task { try await collectActions(from: effect) }
        await base.waitForReads(1)
        await base.finishRead(1, cancelled: true, snapshot: .init())
        for action in try await read.value {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(!state.paywall.isLoading)
        #expect(state.paywall.error != nil)
    }

    @Test("obsolete cancellation cannot finish a newer refresh")
    @MainActor
    func cancelledOlderRefreshPreservesNewerLoading() async throws {
        let base = ConcurrentPaywallService()
        let plugin = makePlugin(service: base)
        var state = TestState()
        let first = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let firstRead = Task { try await collectActions(from: first) }
        await base.waitForReads(1)
        let second = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let secondRead = Task { try await collectActions(from: second) }
        await base.waitForReads(2)
        firstRead.cancel()
        await base.finishRead(1, snapshot: .init())
        for action in try await firstRead.value {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(state.paywall.isLoading)
        await base.finishRead(2, snapshot: .init(isPro: true))
        for action in try await secondRead.value {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(state.paywall.isPro)
        #expect(!state.paywall.isLoading)
    }

    @Test("cancellation finishes loading even while the provider remains suspended")
    @MainActor
    func cancellationDoesNotWaitForProvider() async throws {
        let base = ConcurrentPaywallService()
        let plugin = makePlugin(service: base)
        var state = TestState()
        let effect = try #require(plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo)))
        let (finished, continuation) = AsyncStream<Void>.makeStream()
        let read = Task {
            try await effect { action in
                _ = plugin.reduce(state: &state, action: action)
                if !state.paywall.isLoading { continuation.yield(()) }
            }
        }
        await base.waitForReads(1)
        read.cancel()
        let completedBeforeProvider = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = finished.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
        await base.finishRead(1, snapshot: .init(isPro: true))
        try await read.value
        continuation.finish()
        #expect(completedBeforeProvider)
        #expect(!state.paywall.isLoading)
        #expect(!state.paywall.isPro)
    }

    @Test("a cached stream seed cannot invalidate an in-flight live refresh", arguments: [false, true])
    @MainActor
    func cachedSeedCannotInvalidateLiveRefresh(liveIsPro: Bool) async throws {
        let store = InMemoryKeyValueStore()
        store.setValue(
            CachedEntitlement(isPro: !liveIsPro, hasPermanentLicense: false), for: .lastKnownEntitlement)
        let base = SuspendedPaywallService()
        base.updates.finish()
        let service = ResilientPaywallService(base: base, store: store)
        let plugin = makePlugin(service: service)
        var state = TestState()
        let refresh = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let read = Task { try await collectActions(from: refresh) }
        await base.waitForRead()

        let observation = plugin.reduce(state: &state, action: .paywall(.observeCustomerInfo))
        for action in try await collectActions(from: observation) {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(state.paywall.isPro == !liveIsPro, "the cache still seeds the initial gate")
        #expect(state.paywall.isLoading, "a provisional seed does not complete the pending refresh")
        await base.finishRead(snapshot: .init(isPro: liveIsPro))
        for action in try await read.value {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(state.paywall.isPro == liveIsPro)
        #expect(!state.paywall.isLoading)
        #expect(store.value(.lastKnownEntitlement)?.isPro == liveIsPro)
    }

    @Test("a delayed cached seed cannot replace an already resolved live entitlement")
    @MainActor
    func delayedSeedCannotOverwriteLiveResult() async throws {
        let store = InMemoryKeyValueStore()
        store.setValue(CachedEntitlement(isPro: false, hasPermanentLicense: false), for: .lastKnownEntitlement)
        let base = SuspendedPaywallService()
        base.updates.finish()
        let plugin = makePlugin(service: ResilientPaywallService(base: base, store: store))
        var state = TestState()
        let refresh = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let read = Task { try await collectActions(from: refresh) }
        await base.waitForRead()
        let observation = plugin.reduce(state: &state, action: .paywall(.observeCustomerInfo))
        let seededActions = try await collectActions(from: observation)

        await base.finishRead(snapshot: .init(isPro: true))
        for action in try await read.value {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        for action in seededActions {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(state.paywall.isPro)
    }

    @Test("a cached fallback still completes a failed live refresh after seeding")
    @MainActor
    func cacheFallbackCompletesRefresh() async throws {
        let store = InMemoryKeyValueStore()
        store.setValue(CachedEntitlement(isPro: true, hasPermanentLicense: false), for: .lastKnownEntitlement)
        let base = SuspendedPaywallService()
        base.updates.finish()
        let service = ResilientPaywallService(base: base, store: store, maxAttempts: 1)
        let plugin = makePlugin(service: service)
        var state = TestState()
        let refresh = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let read = Task { try await collectActions(from: refresh) }
        await base.waitForRead()
        let observation = plugin.reduce(state: &state, action: .paywall(.observeCustomerInfo))
        for action in try await collectActions(from: observation) {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        await base.finishRead(fails: true)
        let actions = try await read.value
        for action in actions {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(!actions.isEmpty)
        #expect(state.paywall.isPro)
        #expect(!state.paywall.isLoading)
        #expect(state.paywall.error == nil)
    }

    @Test("an old refresh cannot overwrite a paid update or attach a stale error", arguments: [false, true])
    @MainActor
    func refreshCannotOverwriteNewerUpdate(fails: Bool) async throws {
        let base = SuspendedPaywallService()
        let plugin = makePlugin(service: base)
        var state = TestState()
        let effect = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let read = Task { try await collectActions(from: effect) }
        await base.waitForRead()

        _ = plugin.reduce(state: &state, action: .paywall(.customerInfoUpdated(.init(isPro: true))))
        await base.finishRead(fails: fails)
        let actions = try await read.value
        for action in actions {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(state.paywall.isPro)
        #expect(state.paywall.error == nil)
        #expect(!state.paywall.isLoading)
    }

    @Test("an old refresh cannot undo a newer restore")
    @MainActor
    func refreshCannotOverwriteRestore() async throws {
        let base = SuspendedPaywallService()
        let plugin = makePlugin(service: base)
        var state = TestState()
        let effect = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let read = Task { try await collectActions(from: effect) }
        await base.waitForRead()

        let restore = plugin.reduce(state: &state, action: .paywall(.restorePurchases))
        for action in try await collectActions(from: restore) {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        await base.finishRead()
        for action in try await read.value {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(state.paywall.isPro)
    }

    @Test("a cancelled refresh ignores a provider success and finishes its own loading")
    @MainActor
    func cancelledRefreshDoesNotPublishSnapshot() async throws {
        let base = SuspendedPaywallService()
        let plugin = makePlugin(service: base)
        var state = TestState()
        let effect = plugin.reduce(state: &state, action: .paywall(.refreshCustomerInfo))
        let read = Task { try await collectActions(from: effect) }
        await base.waitForRead()
        read.cancel()
        await base.finishRead(snapshot: .init(isPro: true))
        for action in try await read.value {
            _ = plugin.reduce(state: &state, action: .paywall(action))
        }
        #expect(!state.paywall.isPro)
        #expect(!state.paywall.isLoading)
        #expect(state.paywall.error == nil)
    }

    @Test("an old live read cannot overwrite the streamed cache")
    func refreshCannotOverwriteStreamCache() async throws {
        let store = InMemoryKeyValueStore()
        let base = SuspendedPaywallService()
        let service = ResilientPaywallService(base: base, store: store, seedsFromCache: false)
        let read = Task { try await service.customerInfo() }
        await base.waitForRead()
        var iterator = service.customerInfoStream().makeAsyncIterator()
        base.updates.yield(.init(isPro: true))
        #expect(await iterator.next()?.isPro == true)

        await base.finishRead()
        #expect(try await read.value.isPro)
        #expect(store.value(.lastKnownEntitlement)?.isPro == true)
        base.updates.finish()
    }

    @Test("an old live read cannot overwrite the restored cache")
    func refreshCannotOverwriteRestoreCache() async throws {
        let store = InMemoryKeyValueStore()
        let base = SuspendedPaywallService()
        let service = ResilientPaywallService(base: base, store: store)
        let read = Task { try await service.customerInfo() }
        await base.waitForRead()
        _ = try await service.restorePurchases()
        await base.finishRead()
        #expect(try await read.value.isPro)
        #expect(store.value(.lastKnownEntitlement)?.isPro == true)
    }

    @Test("cancellation preserves the cache when a provider ignores cancellation")
    func cancelledReadDoesNotPersist() async throws {
        let store = InMemoryKeyValueStore()
        store.setValue(CachedEntitlement(isPro: true, hasPermanentLicense: false), for: .lastKnownEntitlement)
        let base = SuspendedPaywallService()
        let service = ResilientPaywallService(base: base, store: store)
        let read = Task { try await service.customerInfo() }
        await base.waitForRead()
        read.cancel()
        await base.finishRead()
        #expect(try await read.value.isPro)
        #expect(store.value(.lastKnownEntitlement)?.isPro == true)
    }
}

private actor ConcurrentPaywallService: PaywallService {
    private var callCount = 0
    private var pending: [Int: CheckedContinuation<EntitlementSnapshot, any Error>] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func customerInfo() async throws -> EntitlementSnapshot {
        callCount += 1
        let index = callCount
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            waiters.removeValue(forKey: index)?.resume()
        }
    }

    func waitForReads(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { waiters[count] = $0 }
    }

    func finishRead(_ index: Int, fails: Bool = false, cancelled: Bool = false, snapshot: EntitlementSnapshot) {
        if cancelled {
            pending.removeValue(forKey: index)?.resume(throwing: CancellationError())
        } else if fails {
            pending.removeValue(forKey: index)?.resume(throwing: ReadError.failed)
        } else {
            pending.removeValue(forKey: index)?.resume(returning: snapshot)
        }
    }

    nonisolated func customerInfoStream() -> AsyncStream<EntitlementSnapshot> { AsyncStream { $0.finish() } }
    func restorePurchases() async throws -> EntitlementSnapshot { .init(isPro: true) }
    private enum ReadError: Error { case failed }
}

private actor SuspendedPaywallService: PaywallService {
    nonisolated let updates: AsyncStream<EntitlementSnapshot>.Continuation
    private nonisolated let stream: AsyncStream<EntitlementSnapshot>
    private var pendingRead: CheckedContinuation<EntitlementSnapshot, any Error>?
    private var readStarted: CheckedContinuation<Void, Never>?

    init() {
        (stream, updates) = AsyncStream.makeStream()
    }

    func customerInfo() async throws -> EntitlementSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            pendingRead = continuation
            readStarted?.resume()
            readStarted = nil
        }
    }

    func waitForRead() async {
        guard pendingRead == nil else { return }
        await withCheckedContinuation { readStarted = $0 }
    }

    func finishRead(fails: Bool = false, snapshot: EntitlementSnapshot = .init()) {
        if fails {
            pendingRead?.resume(throwing: ReadError.failed)
        } else {
            pendingRead?.resume(returning: snapshot)
        }
        pendingRead = nil
    }

    nonisolated func customerInfoStream() -> AsyncStream<EntitlementSnapshot> { stream }

    func restorePurchases() async throws -> EntitlementSnapshot { .init(isPro: true) }

    private enum ReadError: Error { case failed }
}
