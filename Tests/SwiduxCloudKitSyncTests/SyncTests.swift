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
import Synchronization
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

    @Test("CloudKit rejecting the build's entitlements is a build misconfiguration too")
    func rejectedByCloudKit() {
        // Not "sign in to iCloud": nothing the user does fixes a bad container.
        #expect(
            SyncStatus.resolve(desired: .iCloud, entitled: true, account: .misconfigured) == .misconfiguredNoEntitlement
        )
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

    @Test("a stored choice that can't be decoded fails closed to local-only")
    func undecodableFailsClosed() {
        // Something is stored under the key, but not a `SyncMode` — an older
        // build's `Bool`, say. That is not a fresh install: someone made a
        // choice, and the one that can't upload their data is the safe reading.
        let store = InMemoryKeyValueStore()
        store.setValue(false, for: KVKey<Bool>(KVKey<SyncMode>.syncMode.name))
        #expect(store.contains(.syncMode))
        #expect(store.value(.syncMode) == nil)

        #expect(resolveDesiredSyncMode(from: store) == .localOnly)
        #expect(resolveDesiredSyncMode(from: store, default: .iCloud) == .localOnly)
    }
}

// MARK: - Toggle

@Suite("SyncCoordinator")
struct SyncCoordinatorTests {
    @MainActor
    @Test("an older enable cannot reverse a completed opt-out")
    func olderEnableCannotReverseNewerOptOut() async throws {
        let local = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)], container: local)
        let preferences = InMemoryKeyValueStore()
        let gate = SyncToggleGate()
        var builtModes: [SyncMode] = []
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence, models: [ItemModel.self], mode: .localOnly,
            preflight: SyncPreflightService(
                isEntitled: { true },
                accountState: {
                    await gate.pauseFirstCall()
                    return .available
                }),
            keyValue: preferences,
            makeContainer: { mode in
                builtModes.append(mode)
                return local
            })
        let appStore = makeItemsStore(persistence)
        let older = Task { await sync.setSyncEnabled(true, into: appStore) }
        await gate.waitUntilPaused()
        let newerStatus = await sync.setSyncEnabled(false, into: appStore)
        await gate.release()
        let olderStatus = await older.value

        #expect(newerStatus == .localOnlyByChoice)
        #expect(olderStatus == .localOnlyByChoice)
        #expect(sync.mode == .localOnly)
        #expect(preferences.value(.syncMode) == .localOnly)
        #expect(builtModes == [.localOnly])
    }

    @MainActor
    @Test("an enable overtaken during hydration returns the newer opt-out status")
    func optOutSupersedesOlderHydration() async throws {
        let local = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let cloud = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let cloudID = UUID()
        try await EntityDB(modelContainer: cloud).upsert(
            Item(id: cloudID, label: "old cloud read"), as: ItemModel.self)
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)], container: local)
        let preferences = InMemoryKeyValueStore()
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence, models: [ItemModel.self], mode: .localOnly,
            preflight: .mock(entitled: true, account: .available),
            keyValue: preferences, makeContainer: { $0 == .iCloud ? cloud : local })
        let gate = SyncToggleGate()
        persistence.duringReadPhase = { await gate.pauseFirstCall() }
        let appStore = makeItemsStore(persistence)
        let older = Task { await sync.setSyncEnabled(true, into: appStore) }
        await gate.waitUntilPaused()
        let newerStatus = await sync.setSyncEnabled(false, into: appStore)
        await gate.release()
        let olderStatus = await older.value

        #expect(newerStatus == .localOnlyByChoice)
        #expect(olderStatus == .localOnlyByChoice)
        #expect(sync.mode == .localOnly)
        #expect(preferences.value(.syncMode) == .localOnly)
        #expect(appStore.items[cloudID] == nil)
    }

    @MainActor
    @Test("a peer deleting the last row after a toggle is not lost, and not resurrected")
    func toggleKeepsALastRowDeletion() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)], container: container)
        let id = UUID()
        try await persistence.database.upsert(Item(id: id, label: "only"), as: ItemModel.self)
        let store = makeItemsStore(persistence)
        await persistence.hydrate(into: store)

        // Both modes over one store, as CloudContainerFactory arranges.
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence, models: [ItemModel.self], mode: .localOnly,
            preflight: .mock(entitled: true, account: .available),
            keyValue: InMemoryKeyValueStore(), makeContainer: { _ in container })
        #expect(await sync.setSyncEnabled(true, into: store) == .syncing)

        // A peer deletes the row, and mirroring imports the delete.
        try await EntityDB(modelContainer: container).delete(id: id, as: ItemModel.self)
        await persistence.mergeChanges(into: store)
        #expect(store.items[id] == nil, "the first tick after a toggle must see the tombstone")

        // The user edits the row if they can still see it.
        if store.items[id] != nil { store.send(.add(Item(id: id, label: "edited"))) }
        await persistence.corePlugin.flush()
        let onDisk = try await persistence.fetchAll(of: Item.self)
        #expect(!onDisk.contains { $0.id == id }, "the deleted row was resurrected on disk, and so on every peer")
    }

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
            preflight: .mock(entitled: true, account: .available),
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
    @Test("opting out consults no probe, so the mirrored container isn't held open on one")
    func optOutSkipsPreflight() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)], container: container)
        let probes = Mutex(0)
        var builtModes: [SyncMode] = []
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence, models: [ItemModel.self], mode: .iCloud,
            preflight: SyncPreflightService(
                isEntitled: {
                    probes.withLock { $0 += 1 }
                    return false
                },
                accountState: {
                    probes.withLock { $0 += 1 }
                    return .couldNotDetermine
                }),
            keyValue: InMemoryKeyValueStore(),
            makeContainer: { mode in
                builtModes.append(mode)
                return container
            })

        let status = await sync.setSyncEnabled(false, into: makeItemsStore(persistence))

        #expect(status == .localOnlyByChoice)
        #expect(builtModes == [.localOnly])
        // Neither probe can change an opt-out's outcome. The account probe is a
        // CloudKit round trip the mirrored container would stay live across, and
        // in an unentitled build it doesn't return at all.
        #expect(probes.withLock { $0 } == 0)
    }

    @MainActor
    @Test("enabling while signed out still attaches the mirror, so signing in later syncs")
    func enableWhileSignedOutAttachesMirror() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [ItemModel.self])
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)], container: container)
        let account = Mutex<ICloudAccountState>(.noAccount)
        var builtModes: [SyncMode] = []
        let preferences = InMemoryKeyValueStore()
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence, models: [ItemModel.self], mode: .localOnly,
            preflight: SyncPreflightService(
                isEntitled: { true },
                accountState: { account.withLock { $0 } }),
            keyValue: preferences,
            makeContainer: { mode in
                builtModes.append(mode)
                return container
            })

        let first = await sync.setSyncEnabled(true, into: makeItemsStore(persistence))
        #expect(first == .unavailableNotSignedIn)
        #expect(sync.mode == .iCloud)
        #expect(preferences.value(.syncMode) == .iCloud)
        // The same container launch would build from that preference. A mirrored
        // container tolerates a signed-out account and starts on sign-in; a
        // local one would stay local until the next launch.
        #expect(builtModes == [.iCloud])

        // The user signs in and comes back. The status now describes the
        // container that is actually active.
        account.withLock { $0 = .available }
        #expect(await sync.currentStatus() == .syncing)
    }

    @MainActor
    @Test("the default rebuild opens the store the app launched with")
    func defaultRebuildReusesLaunchStore() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swidux-sync-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("group.store")

        let launch = try CloudContainerFactory.makeContainer(models: [ItemModel.self], mode: .localOnly, url: url)
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)], container: launch)
        let id = UUID()
        try await persistence.database.upsert(Item(id: id, label: "on disk"), as: ItemModel.self)
        // No `storeURL:` and no builder — the shape an app-group app gets wrong
        // by omission. Opting out rebuilds through `CloudContainerFactory`,
        // which stays hermetic in `.localOnly`.
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence, models: [ItemModel.self], mode: .iCloud,
            preflight: .mock(entitled: true, account: .available),
            keyValue: InMemoryKeyValueStore())

        #expect(await sync.setSyncEnabled(false, into: makeItemsStore(persistence)) == .localOnlyByChoice)

        // Not SwiftData's `default.store`: that would be a second, empty store,
        // and everything written after the toggle would be missing next launch.
        #expect(persistence.handle.storeURLs == [url.standardizedFileURL])
        #expect(try await persistence.fetchAll(of: Item.self).map(\.id) == [id])
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
            preflight: .mock(entitled: true, account: .available),
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
            preflight: .mock(entitled: true, account: .available),
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
            preflight: .mock(entitled: true, account: .available),
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

private actor SyncToggleGate {
    private var hasPaused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func pauseFirstCall() async {
        guard !hasPaused else { return }
        hasPaused = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            arrival?.resume()
            arrival = nil
        }
    }

    func waitUntilPaused() async {
        if hasPaused { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
