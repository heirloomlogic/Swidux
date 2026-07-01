//
//  ResilientPaywallServiceTests.swift
//  SwiduxPaywallTests
//

import Foundation
import Swidux
import Synchronization
import Testing

@testable import SwiduxPaywall

@Suite("ResilientPaywallService")
struct ResilientPaywallServiceTests {
    // MARK: customerInfo

    @Test("successful read persists last-known-good and returns it")
    func successPersistsAndReturns() async throws {
        let store = InMemoryKeyValueStore()
        let base = FlakyPaywallService(success: EntitlementSnapshot(isPro: true))
        let service = ResilientPaywallService(base: base, store: store)

        let snapshot = try await service.customerInfo()

        #expect(snapshot == EntitlementSnapshot(isPro: true))
        #expect(store.value(.lastKnownEntitlement) == CachedEntitlement(isPro: true, hasPermanentLicense: false))
    }

    @Test("permanent-license holder never degrades to free on transient failure")
    func permanentLicenseHolderNeverDegradesToFree() async throws {
        let store = InMemoryKeyValueStore()
        store.setValue(CachedEntitlement(isPro: false, hasPermanentLicense: true), for: .lastKnownEntitlement)
        let base = FlakyPaywallService(failuresBeforeSuccess: .max)  // always fails
        let service = ResilientPaywallService(base: base, store: store, maxAttempts: 2)

        let snapshot = try await service.customerInfo()

        #expect(snapshot.hasPermanentLicense == true)
        #expect(snapshot.isPro == false)
    }

    @Test("subscriber falls back to last-known-good on transient failure")
    func subscriberFallsBackToLastKnownGood() async throws {
        let store = InMemoryKeyValueStore()
        store.setValue(CachedEntitlement(isPro: true, hasPermanentLicense: false), for: .lastKnownEntitlement)
        let base = FlakyPaywallService(failuresBeforeSuccess: .max)
        let service = ResilientPaywallService(base: base, store: store)

        let snapshot = try await service.customerInfo()

        #expect(snapshot.isPro == true)
    }

    @Test("never-seen user surfaces the failure instead of masking it as free")
    func neverSeenUserThrows() async {
        let store = InMemoryKeyValueStore()
        let base = FlakyPaywallService(failuresBeforeSuccess: .max)
        let service = ResilientPaywallService(base: base, store: store)

        await #expect(throws: (any Error).self) {
            _ = try await service.customerInfo()
        }
    }

    @Test("bounded retry recovers within the attempt budget")
    func boundedRetryRecoversWithinBudget() async throws {
        let store = InMemoryKeyValueStore()
        let base = FlakyPaywallService(success: EntitlementSnapshot(isPro: true), failuresBeforeSuccess: 2)
        let service = ResilientPaywallService(base: base, store: store, maxAttempts: 3)

        let snapshot = try await service.customerInfo()

        #expect(snapshot.isPro == true)
        #expect(base.customerInfoCallCount == 3)  // two failures, then success
    }

    @Test("retry is bounded by maxAttempts")
    func retryIsBounded() async {
        let store = InMemoryKeyValueStore()
        let base = FlakyPaywallService(failuresBeforeSuccess: .max)
        let service = ResilientPaywallService(base: base, store: store, maxAttempts: 2)

        await #expect(throws: (any Error).self) {
            _ = try await service.customerInfo()
        }
        #expect(base.customerInfoCallCount == 2)
    }

    @Test("a fresh live snapshot overwrites stale cache (genuine lapse honoured)")
    func freshSuccessOverwritesStaleCache() async throws {
        let store = InMemoryKeyValueStore()
        store.setValue(CachedEntitlement(isPro: true, hasPermanentLicense: true), for: .lastKnownEntitlement)
        // The live read now reports the user as free — a genuine downgrade.
        let base = FlakyPaywallService(success: EntitlementSnapshot())
        let service = ResilientPaywallService(base: base, store: store)

        let snapshot = try await service.customerInfo()

        #expect(snapshot == EntitlementSnapshot())
        #expect(store.value(.lastKnownEntitlement) == CachedEntitlement(isPro: false, hasPermanentLicense: false))
    }

    // MARK: currentSnapshot

    @Test("currentSnapshot returns the cached entitlement when the live read fails")
    func currentSnapshotReturnsCachedWhenPresent() async {
        let store = InMemoryKeyValueStore()
        store.setValue(CachedEntitlement(isPro: true, hasPermanentLicense: false), for: .lastKnownEntitlement)
        let base = FlakyPaywallService(failuresBeforeSuccess: .max)
        let service = ResilientPaywallService(base: base, store: store)

        let snapshot = await service.currentSnapshot()

        #expect(snapshot.isPro == true)
    }

    @Test("currentSnapshot degrades to free for a genuinely-unknown user")
    func currentSnapshotDegradesToFreeForUnknownUser() async {
        let store = InMemoryKeyValueStore()
        let base = FlakyPaywallService(failuresBeforeSuccess: .max)
        let service = ResilientPaywallService(base: base, store: store)

        let snapshot = await service.currentSnapshot()

        #expect(snapshot == EntitlementSnapshot())
    }

    // MARK: customerInfoStream

    @Test("stream seeds the last-known-good first so a flaky launch is not gated as free")
    func streamSeedsLastKnownGoodFirst() async {
        let store = InMemoryKeyValueStore()
        store.setValue(CachedEntitlement(isPro: true, hasPermanentLicense: false), for: .lastKnownEntitlement)
        // Base stream emits nothing this launch (slow/silent read).
        let base = FlakyPaywallService(streamSnapshots: [])
        let service = ResilientPaywallService(base: base, store: store)

        let received = await collect(service.customerInfoStream())

        #expect(received.first == EntitlementSnapshot(isPro: true))
    }

    @Test("stream does not seed from cache when seedsFromCache is off")
    func streamDoesNotSeedWhenDisabled() async {
        let store = InMemoryKeyValueStore()
        store.setValue(CachedEntitlement(isPro: true, hasPermanentLicense: false), for: .lastKnownEntitlement)
        let base = FlakyPaywallService(streamSnapshots: [])
        let service = ResilientPaywallService(base: base, store: store, seedsFromCache: false)

        let received = await collect(service.customerInfoStream())

        #expect(received.isEmpty)
    }

    @Test("stream forwards live snapshots and persists each one")
    func streamForwardsAndPersistsLiveSnapshots() async {
        let store = InMemoryKeyValueStore()
        let live = [
            EntitlementSnapshot(isPro: false),
            EntitlementSnapshot(isPro: true),
            EntitlementSnapshot(isPro: true, hasPermanentLicense: true),
        ]
        let base = FlakyPaywallService(streamSnapshots: live)
        let service = ResilientPaywallService(base: base, store: store)

        let received = await collect(service.customerInfoStream())

        #expect(received == live)  // empty store → no seed, just the live values
        #expect(store.value(.lastKnownEntitlement) == CachedEntitlement(live.last!))
    }

    @Test("a live snapshot persisted in one session seeds the gate in the next")
    func liveSnapshotPersistedSeedsNextSession() async throws {
        let store = InMemoryKeyValueStore()

        // Session 1: a live pro snapshot streams in and is persisted.
        let session1 = ResilientPaywallService(
            base: FlakyPaywallService(streamSnapshots: [EntitlementSnapshot(isPro: true)]),
            store: store
        )
        _ = await collect(session1.customerInfoStream())

        // Session 2: a new decorator over the same store, whose live read fails,
        // still recovers the gate from the persisted last-known-good.
        let session2 = ResilientPaywallService(
            base: FlakyPaywallService(failuresBeforeSuccess: .max),
            store: store
        )
        let snapshot = try await session2.customerInfo()

        #expect(snapshot.isPro == true)
    }

    // MARK: restorePurchases

    @Test("a successful restore persists the snapshot")
    func restoreSuccessPersists() async throws {
        let store = InMemoryKeyValueStore()
        let base = FlakyPaywallService(success: EntitlementSnapshot(hasPermanentLicense: true))
        let service = ResilientPaywallService(base: base, store: store)

        let snapshot = try await service.restorePurchases()

        #expect(snapshot.hasPermanentLicense == true)
        #expect(store.value(.lastKnownEntitlement) == CachedEntitlement(isPro: false, hasPermanentLicense: true))
    }

    @Test("a failed restore rethrows and leaves the cache untouched")
    func restoreFailureRethrows() async {
        let store = InMemoryKeyValueStore()
        let base = FlakyPaywallService(restoreShouldFail: true)
        let service = ResilientPaywallService(base: base, store: store)

        await #expect(throws: (any Error).self) {
            _ = try await service.restorePurchases()
        }
        #expect(store.value(.lastKnownEntitlement) == nil)
    }
}

// MARK: - Test fixtures

private enum TestError: Error {
    case boom
}

/// Configurable `PaywallService` double: fails `customerInfo()` a set number of
/// times before succeeding (`.max` to always fail), emits a fixed list of stream
/// values, and can fail `restorePurchases()` on demand. Counts `customerInfo()`
/// calls so the retry budget can be asserted.
private final class FlakyPaywallService: PaywallService {
    let success: EntitlementSnapshot
    let failuresBeforeSuccess: Int
    let streamSnapshots: [EntitlementSnapshot]
    let restoreShouldFail: Bool
    private let callCount = Mutex(0)

    init(
        success: EntitlementSnapshot = EntitlementSnapshot(),
        failuresBeforeSuccess: Int = 0,
        streamSnapshots: [EntitlementSnapshot] = [],
        restoreShouldFail: Bool = false
    ) {
        self.success = success
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.streamSnapshots = streamSnapshots
        self.restoreShouldFail = restoreShouldFail
    }

    var customerInfoCallCount: Int { callCount.withLock { $0 } }

    func customerInfo() async throws -> EntitlementSnapshot {
        let attempt = callCount.withLock { count -> Int in
            count += 1
            return count
        }
        if attempt <= failuresBeforeSuccess { throw TestError.boom }
        return success
    }

    func customerInfoStream() -> AsyncStream<EntitlementSnapshot> {
        let snapshots = streamSnapshots
        return AsyncStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
    }

    func restorePurchases() async throws -> EntitlementSnapshot {
        if restoreShouldFail { throw TestError.boom }
        return success
    }
}

private func collect(
    _ stream: AsyncStream<EntitlementSnapshot>
) async -> [EntitlementSnapshot] {
    var collected: [EntitlementSnapshot] = []
    for await snapshot in stream {
        collected.append(snapshot)
    }
    return collected
}
