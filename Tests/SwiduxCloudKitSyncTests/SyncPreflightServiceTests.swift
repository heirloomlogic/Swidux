//
//  SyncPreflightServiceTests.swift
//  SwiduxCloudKitSyncTests
//
//  Direct coverage for the preflight service: the closure→resolution wiring,
//  the `.mock` factory across its whole input matrix, and the CloudKit
//  account-status mapping. `SyncStatus.resolve` itself is covered in
//  SyncTests.swift; these exercise the paths that reach it.
//
//  All hermetic — no CloudKit network, no entitlement.
//

import Foundation
import Swidux
import SwiduxPersistence
import SwiftData
import Testing

@testable import SwiduxCloudKitSync

#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - resolve(desired:) — the instance method

@Suite("SyncPreflightService.resolve")
struct SyncPreflightServiceResolveTests {
    /// The full input matrix: entitled × account × desired mode. Guards the
    /// closure→`SyncStatus.resolve` wiring, which the static-function tests
    /// in SyncTests.swift bypass entirely.
    @Test(
        "resolve threads both probes into the expected status",
        arguments: [
            // Local-only ignores both probes.
            (SyncMode.localOnly, false, ICloudAccountState.noAccount, SyncStatus.localOnlyByChoice),
            (.localOnly, true, .available, .localOnlyByChoice),
            (.localOnly, false, .couldNotDetermine, .localOnlyByChoice),
            // iCloud without a ubiquity token is a build misconfiguration,
            // whatever the account says.
            (.iCloud, false, .available, .misconfiguredNoEntitlement),
            (.iCloud, false, .noAccount, .misconfiguredNoEntitlement),
            (.iCloud, false, .restricted, .misconfiguredNoEntitlement),
            (.iCloud, false, .temporarilyUnavailable, .misconfiguredNoEntitlement),
            (.iCloud, false, .couldNotDetermine, .misconfiguredNoEntitlement),
            // iCloud + entitled: the account state decides.
            (.iCloud, true, .available, .syncing),
            (.iCloud, true, .restricted, .unavailableRestricted),
            (.iCloud, true, .noAccount, .unavailableNotSignedIn),
            (.iCloud, true, .temporarilyUnavailable, .unavailableNotSignedIn),
            (.iCloud, true, .couldNotDetermine, .unavailableNotSignedIn),
        ]
    )
    func resolveMatrix(
        desired: SyncMode,
        entitled: Bool,
        account: ICloudAccountState,
        expected: SyncStatus
    ) async {
        let service = SyncPreflightService.mock(ubiquityToken: entitled, account: account)
        #expect(await service.resolve(desired: desired) == expected)
    }

    @Test("both probe closures are actually consulted")
    func probesAreCalled() async {
        // `.mock` returns constants, so drive the memberwise init directly to
        // observe that resolve reads each closure rather than a cached value.
        let tokenCalls = Counter()
        let accountCalls = Counter()
        let service = SyncPreflightService(
            ubiquityTokenAvailable: {
                tokenCalls.increment()
                return true
            },
            accountState: {
                accountCalls.increment()
                return .available
            }
        )

        #expect(await service.resolve(desired: .iCloud) == .syncing)
        #expect(tokenCalls.value == 1)
        #expect(accountCalls.value == 1)
    }

    @Test("the closures are vars, so a probe can be swapped in place")
    func probesAreMutable() async {
        var service = SyncPreflightService.mock(ubiquityToken: true, account: .available)
        #expect(await service.resolve(desired: .iCloud) == .syncing)

        service.accountState = { .restricted }
        #expect(await service.resolve(desired: .iCloud) == .unavailableRestricted)

        service.ubiquityTokenAvailable = { false }
        #expect(await service.resolve(desired: .iCloud) == .misconfiguredNoEntitlement)
    }
}

// MARK: - CKAccountStatus mapping

#if canImport(CloudKit)
@Suite("SyncPreflightService.mapAccountStatus")
struct SyncPreflightAccountStatusTests {
    @Test(
        "each CKAccountStatus maps to its coarse state",
        arguments: [
            (CKAccountStatus.available, ICloudAccountState.available),
            (.noAccount, .noAccount),
            (.restricted, .restricted),
            (.temporarilyUnavailable, .temporarilyUnavailable),
            (.couldNotDetermine, .couldNotDetermine),
        ]
    )
    func knownStatuses(status: CKAccountStatus, expected: ICloudAccountState) {
        #expect(SyncPreflightService.mapAccountStatus(status) == expected)
    }

    @Test("an unrecognised raw status falls back to couldNotDetermine")
    func unknownStatusFallsBack() throws {
        // Exercises the `@unknown default` arm: a status value from a future
        // OS must degrade to unknown rather than trap or claim availability.
        // `#require` rather than an `if let` — if a future SDK stops vending
        // unrecognised raw values this test should fail loudly, not pass
        // vacuously while covering nothing.
        let future = try #require(
            CKAccountStatus(rawValue: 9999),
            "expected an unrecognised CKAccountStatus to be constructible"
        )
        #expect(SyncPreflightService.mapAccountStatus(future) == .couldNotDetermine)
    }
}
#endif

// MARK: - CloudContainerFactory

@Suite("CloudContainerFactory")
struct CloudContainerFactoryTests {
    /// Only `.localOnly` is asserted here. `.iCloud` selects `.private(id)` /
    /// `.automatic`, which normally wants a real iCloud entitlement to build,
    /// so exercising it would make the suite non-hermetic on CI.
    @MainActor
    @Test("localOnly builds a container with no CloudKit mirror attached")
    func localOnlyOmitsCloudKit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swidux-cloudfactory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")

        let container = try CloudContainerFactory.makeContainer(
            models: [ItemModel.self],
            mode: .localOnly,
            url: url
        )

        let configuration = try #require(container.configurations.first)
        #expect(configuration.cloudKitContainerIdentifier == nil)
        #expect(configuration.url == url)
    }

    @MainActor
    @Test("the store URL is shared across modes so toggling never moves rows")
    func sameURLAcrossModes() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swidux-cloudfactory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")

        let first = try CloudContainerFactory.makeContainer(
            models: [ItemModel.self], mode: .localOnly, url: url)
        let id = UUID()
        try await EntityDB(modelContainer: first).upsert(
            Item(id: id, label: "kept"), as: ItemModel.self)

        // Rebuilding local-only at the same URL must reopen the same rows —
        // this is the invariant that makes the sync toggle non-destructive.
        let second = try CloudContainerFactory.makeContainer(
            models: [ItemModel.self], mode: .localOnly, url: url)
        let rows = try await EntityDB(modelContainer: second).fetchAll(ItemModel.self)
        #expect(rows.map(\.label) == ["kept"])
    }
}

// MARK: - Rebuild failure

@Suite("SyncCoordinator rebuild failure")
struct SyncCoordinatorRebuildFailureTests {
    private struct BuilderFailure: Error {}

    @MainActor
    @Test("a container that won't build leaves mode, preference, and data untouched")
    func rebuildFailureIsInert() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, Never>(
            entities: [.entity(\.items)],
            container: container
        )
        let store = InMemoryKeyValueStore()
        let sync = SyncCoordinator<ItemsState, Never>(
            persistence: persistence,
            models: [ItemModel.self],
            mode: .localOnly,
            preflight: .mock(ubiquityToken: true, account: .available),
            keyValue: store,
            makeContainer: { _ in throw BuilderFailure() }
        )

        let id = UUID()
        try await persistence.database.upsert(Item(id: id, label: "kept"), as: ItemModel.self)
        var state = ItemsState()
        await persistence.hydrate(into: &state)

        let status = await sync.setSyncEnabled(true, into: &state)

        // The toggle did not take effect, so nothing about it may be recorded.
        #expect(status == .unavailableRebuildFailed)
        #expect(sync.mode == .localOnly)
        #expect(store.value(.syncMode) == nil)
        // The previous database stays active and its rows stay reachable.
        #expect(state.items[id]?.label == "kept")
    }
}

// MARK: - Helpers

/// Minimal call counter. Not `Sendable`-shared across tasks — the probes run
/// inline within `resolve`, so plain reference semantics are enough.
private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}
