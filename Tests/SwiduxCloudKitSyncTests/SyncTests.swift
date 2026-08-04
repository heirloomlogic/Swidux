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
import SwiftData
import Testing

@testable import SwiduxCloudKitSync

// @testable for the `duringReadPhase` seam used by the lost-write test.
@testable import SwiduxPersistence

// MARK: - Fixtures

@Persisted
struct Item: Identifiable, Equatable, Sendable {
    var id: UUID
    var label: String
}

struct ItemsState: Equatable, Sendable {
    var items = EntityStore<Item>()
}

@Observable
@MainActor
final class ItemsStateObserver {
    var items: EntityStore<Item>
    init(items: EntityStore<Item> = EntityStore()) { self.items = items }
}

extension ItemsState: SwiduxObservable {
    typealias Observer = ItemsStateObserver

    @MainActor init(observer: ItemsStateObserver) { self.items = observer.items }

    @MainActor static func makeObserver(from state: ItemsState) -> ItemsStateObserver {
        ItemsStateObserver(items: state.items)
    }

    @MainActor static func apply(_ snapshot: ItemsState, to observer: ItemsStateObserver) {
        observer.items = snapshot.items
    }

    @MainActor static func applyRestore(from snapshot: ItemsState, to current: inout ItemsState) {
        current.items.restore(from: snapshot.items)
    }
}

enum ItemsAction: Equatable, Sendable {
    case add(Item)
}

@MainActor
func itemsReducer(state: inout ItemsState, action: ItemsAction) -> Effect<ItemsAction>? {
    switch action {
    case .add(let item): state.items[item.id] = item
    }
    return nil
}

/// Builds a live store over `coordinator`, seeded from `initialState`.
@MainActor
func makeItemsStore(
    _ coordinator: PersistenceCoordinator<ItemsState, ItemsAction>,
    initialState: ItemsState = ItemsState()
) -> Store<ItemsState, ItemsAction> {
    let plugins = PluginHost<ItemsState, ItemsAction>()
    plugins.register(coordinator.corePlugin)
    return Store(
        initialState: initialState,
        reducer: itemsReducer,
        plugins: plugins,
        persistencePlugin: coordinator.corePlugin
    )
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
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)],
            container: container
        )
        let store = InMemoryKeyValueStore()
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence,
            models: [ItemModel.self],
            mode: .iCloud,
            preflight: .mock(ubiquityToken: true, account: .available),
            keyValue: store
        )

        let id = UUID()
        try await persistence.database.upsert(Item(id: id, label: "kept"), as: ItemModel.self)
        var initial = ItemsState()
        await persistence.hydrate(into: &initial)
        #expect(initial.items[id]?.label == "kept")
        let appStore = makeItemsStore(persistence, initialState: initial)

        let status = await sync.setSyncEnabled(false, into: appStore)
        #expect(status == .localOnlyByChoice)
        #expect(sync.mode == .localOnly)
        #expect(store.value(.syncMode) == .localOnly)
        // Data survives the toggle (merge-based rehydrate, never replace).
        #expect(appStore.items[id]?.label == "kept")
    }

    @MainActor
    @Test("opting in swaps to the rebuilt container and merges its rows")
    func optInRebuildsAndMerges() async throws {
        let local = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)],
            container: local
        )

        // A separate container standing in for the rebuilt CloudKit store,
        // pre-seeded with a row that should arrive after the swap + rehydrate.
        let rebuilt = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let id = UUID()
        try await EntityDB(modelContainer: rebuilt).upsert(Item(id: id, label: "from cloud"), as: ItemModel.self)

        let store = InMemoryKeyValueStore()
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence,
            models: [ItemModel.self],
            mode: .localOnly,
            preflight: .mock(ubiquityToken: true, account: .available),
            keyValue: store,
            makeContainer: { _ in rebuilt }
        )

        let appStore = makeItemsStore(persistence)
        let status = await sync.setSyncEnabled(true, into: appStore)

        #expect(status == .syncing)
        #expect(sync.mode == .iCloud)
        #expect(store.value(.syncMode) == .iCloud)
        // The rebuilt container's row merged into live state.
        #expect(appStore.items[id]?.label == "from cloud")
    }

    @MainActor
    @Test("a write dispatched while the toggle is in flight survives it")
    func toggleKeepsConcurrentWrite() async throws {
        let local = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)],
            container: local,
            debounce: .seconds(30)
        )
        let rebuilt = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let cloudID = UUID()
        try await EntityDB(modelContainer: rebuilt).upsert(
            Item(id: cloudID, label: "from cloud"), as: ItemModel.self)

        let store = InMemoryKeyValueStore()
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence,
            models: [ItemModel.self],
            mode: .localOnly,
            preflight: .mock(ubiquityToken: true, account: .available),
            keyValue: store,
            makeContainer: { _ in rebuilt }
        )

        let appStore = makeItemsStore(persistence)
        // Lands after the flush, preflight and container rebuild — the window a
        // caller holding a state snapshot across those awaits would lose.
        let live = Item(id: UUID(), label: "typed mid-toggle")
        persistence.duringReadPhase = { appStore.send(.add(live)) }

        await sync.setSyncEnabled(true, into: appStore)

        #expect(appStore.items[live.id] == live, "the concurrent write must survive the toggle")
        #expect(appStore.items[cloudID]?.label == "from cloud")
    }

    @MainActor
    @Test("a container-build failure is caught and leaves existing data intact")
    func builderFailureIsCaught() async throws {
        struct BuildFailed: Error {}

        let container = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)],
            container: container
        )
        let id = UUID()
        try await persistence.database.upsert(Item(id: id, label: "local"), as: ItemModel.self)
        var initial = ItemsState()
        await persistence.hydrate(into: &initial)
        let appStore = makeItemsStore(persistence, initialState: initial)

        let store = InMemoryKeyValueStore()
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence,
            models: [ItemModel.self],
            mode: .localOnly,
            preflight: .mock(ubiquityToken: true, account: .available),
            keyValue: store,
            makeContainer: { _ in throw BuildFailed() }
        )

        let status = await sync.setSyncEnabled(true, into: appStore)
        // The toggle did not take effect: status reports the failure, the
        // mode is unchanged, and the choice was not persisted for next launch.
        #expect(status == .unavailableRebuildFailed)
        #expect(sync.mode == .localOnly)
        #expect(store.value(.syncMode) == nil)
        // Rebuild threw, was caught; the original database and its data are intact.
        #expect(appStore.items[id]?.label == "local")
    }
}
