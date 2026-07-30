//
//  SyncTests.swift
//  SwiduxCloudKitSyncTests
//
//  Pure/testable parts of the sync layer: status resolution, the mock
//  preflight, sync-mode preference persistence, and the opt-out toggle path
//  (real CloudKit mirroring is covered by a manual device smoke test).
//

import Foundation
import Swidux
import SwiduxPersistence
import SwiftData
import Testing

@testable import SwiduxCloudKitSync

// MARK: - Fixtures

@Persisted
struct Item: Identifiable, Equatable, Sendable {
    var id: UUID
    var label: String
}

struct ItemsState {
    var items = EntityStore<Item>()
}

// MARK: - SyncStatus.resolve

@Suite("SyncStatus.resolve")
struct SyncStatusResolveTests {
    @Test("local-only is never degraded by account state")
    func localOnly() {
        #expect(SyncStatus.resolve(desired: .localOnly, entitled: false, account: .noAccount) == .localOnlyByChoice)
        #expect(SyncStatus.resolve(desired: .localOnly, entitled: true, account: .available) == .localOnlyByChoice)
    }

    @Test("iCloud without entitlement is a build misconfiguration")
    func misconfigured() {
        #expect(
            SyncStatus.resolve(desired: .iCloud, entitled: false, account: .available) == .misconfiguredNoEntitlement)
    }

    @Test("iCloud, entitled, account state maps to status")
    func entitledAccounts() {
        #expect(SyncStatus.resolve(desired: .iCloud, entitled: true, account: .available) == .syncing)
        #expect(SyncStatus.resolve(desired: .iCloud, entitled: true, account: .noAccount) == .unavailableNotSignedIn)
        #expect(SyncStatus.resolve(desired: .iCloud, entitled: true, account: .restricted) == .unavailableRestricted)
        #expect(
            SyncStatus.resolve(desired: .iCloud, entitled: true, account: .couldNotDetermine) == .unavailableNotSignedIn
        )
        #expect(
            SyncStatus.resolve(desired: .iCloud, entitled: true, account: .temporarilyUnavailable)
                == .unavailableNotSignedIn
        )
    }
}

// MARK: - Preference

@Suite("SyncModePreference")
struct SyncModePreferenceTests {
    @Test("default is iCloud (sync-on with opt-out) when unset")
    func defaultsToICloud() {
        let store = InMemoryKeyValueStore()
        #expect(resolveDesiredSyncMode(from: store) == .iCloud)
        #expect(resolveDesiredSyncMode(from: store, default: .localOnly) == .localOnly)
    }

    @Test("persisted choice round-trips")
    func roundTrips() {
        let store = InMemoryKeyValueStore()
        store.setValue(SyncMode.localOnly, for: .syncMode)
        #expect(resolveDesiredSyncMode(from: store) == .localOnly)
    }
}

// MARK: - Toggle

@Suite("SyncCoordinator")
struct SyncCoordinatorTests {
    @MainActor
    @Test("opting out keeps local data and persists the choice")
    func optOutKeepsData() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, Never>(
            entities: [.entity(\.items)],
            container: container
        )
        let store = InMemoryKeyValueStore()
        let sync = SyncCoordinator<ItemsState, Never>(
            persistence: persistence,
            models: [ItemModel.self],
            mode: .iCloud,
            preflight: .mock(ubiquityToken: true, account: .available),
            keyValue: store
        )

        let id = UUID()
        try await persistence.database.upsert(Item(id: id, label: "kept"), as: ItemModel.self)
        var state = ItemsState()
        await persistence.hydrate(into: &state)
        #expect(state.items[id]?.label == "kept")

        let status = await sync.setSyncEnabled(false, into: &state)
        #expect(status == .localOnlyByChoice)
        #expect(sync.mode == .localOnly)
        #expect(store.value(.syncMode) == .localOnly)
        // Data survives the toggle (merge-based rehydrate, never replace).
        #expect(state.items[id]?.label == "kept")
    }

    @MainActor
    @Test("opting in swaps to the rebuilt container and merges its rows")
    func optInRebuildsAndMerges() async throws {
        let local = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, Never>(
            entities: [.entity(\.items)],
            container: local
        )

        // A separate container standing in for the rebuilt CloudKit store,
        // pre-seeded with a row that should arrive after the swap + rehydrate.
        let rebuilt = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let id = UUID()
        try await EntityDB(modelContainer: rebuilt).upsert(Item(id: id, label: "from cloud"), as: ItemModel.self)

        let store = InMemoryKeyValueStore()
        let sync = SyncCoordinator<ItemsState, Never>(
            persistence: persistence,
            models: [ItemModel.self],
            mode: .localOnly,
            preflight: .mock(ubiquityToken: true, account: .available),
            keyValue: store,
            makeContainer: { _ in rebuilt }
        )

        var state = ItemsState()
        let status = await sync.setSyncEnabled(true, into: &state)

        #expect(status == .syncing)
        #expect(sync.mode == .iCloud)
        #expect(store.value(.syncMode) == .iCloud)
        // The rebuilt container's row merged into live state.
        #expect(state.items[id]?.label == "from cloud")
    }

    @MainActor
    @Test("a container-build failure is caught and leaves existing data intact")
    func builderFailureIsCaught() async throws {
        struct BuildFailed: Error {}

        let container = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, Never>(
            entities: [.entity(\.items)],
            container: container
        )
        let id = UUID()
        try await persistence.database.upsert(Item(id: id, label: "local"), as: ItemModel.self)
        var state = ItemsState()
        await persistence.hydrate(into: &state)

        let store = InMemoryKeyValueStore()
        let sync = SyncCoordinator<ItemsState, Never>(
            persistence: persistence,
            models: [ItemModel.self],
            mode: .localOnly,
            preflight: .mock(ubiquityToken: true, account: .available),
            keyValue: store,
            makeContainer: { _ in throw BuildFailed() }
        )

        let status = await sync.setSyncEnabled(true, into: &state)
        // The toggle did not take effect: status reports the failure, the
        // mode is unchanged, and the choice was not persisted for next launch.
        #expect(status == .unavailableRebuildFailed)
        #expect(sync.mode == .localOnly)
        #expect(store.value(.syncMode) == nil)
        // Rebuild threw, was caught; the original database and its data are intact.
        #expect(state.items[id]?.label == "local")
    }
}
