//
//  RelationSyncTests.swift
//  SwiduxCloudKitSyncTests
//
//  CloudKit mirroring requires an inverse on every relationship, and a
//  `@Relation` has none. Building a mirrored container over one has to fail as
//  a thrown, readable error — at launch from `CloudContainerFactory`, and on a
//  toggle as `.unavailableRebuildFailed` — not as a store that fails to load.
//
//  There is no positive control that builds a real mirrored container: on an
//  unsigned `swift test` host, CloudKit mirroring aborts the process in the
//  background ("bundleIdentifier != nil") once such a container loads.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxCloudKitSync
@testable import SwiduxPersistence

// MARK: - Fixtures

@Persisted
struct Slat: Identifiable, Equatable, Sendable {
    var id: UUID
    var length: Int = 0
}

/// A parent owning children through a `@Relation`: fine locally, and exactly
/// the shape CloudKit refuses.
@Persisted
struct Crate: Identifiable, Equatable, Sendable {
    var id: UUID
    @Relation(deleteRule: .cascade) var slats: [Slat] = []
}

private let probeContainerID = "iCloud.com.heirloomlogic.swidux.relationsync"

/// A fresh on-disk store location, so no test shares a file with another.
private func temporaryStoreURL() throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "swidux-relation-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "store.sqlite")
}

// MARK: - Tests

@Suite("@Relation and CloudKit")
struct RelationSyncTests {
    @Test("the launch factory refuses a mirrored container over a @Relation model, naming it")
    func theLaunchFactoryThrows() throws {
        let error = #expect(throws: CloudKitIncompatibleSchema.self) {
            try CloudContainerFactory.makeContainer(
                models: [CrateModel.self, SlatModel.self], mode: .iCloud, url: try temporaryStoreURL(),
                cloudKitContainerID: probeContainerID)
        }
        #expect(error?.oneSidedRelationships.map(\.description) == ["CrateModel.slats → SlatModel"])
    }

    @Test("the same models build local-only")
    func localOnlyBuilds() throws {
        let container = try CloudContainerFactory.makeContainer(
            models: [CrateModel.self, SlatModel.self], mode: .localOnly, url: try temporaryStoreURL(),
            cloudKitContainerID: probeContainerID)
        #expect(container.configurations.first?.cloudKitContainerIdentifier == nil)
    }

    @MainActor
    @Test("turning sync on over a @Relation model reports a failed rebuild and changes nothing")
    func theToggleReportsARebuildFailure() async throws {
        let models: [any PersistentModel.Type] = [ItemModel.self, CrateModel.self, SlatModel.self]
        let local = try ContainerFactory.makeLocalContainer(models: models, url: try temporaryStoreURL())
        let persistence = PersistenceCoordinator<ItemsState, ItemsAction>(
            entities: [.entity(\.items)], container: local)
        let id = UUID()
        try await persistence.database.upsert(Item(id: id, label: "local"), as: ItemModel.self)
        let store = makeItemsStore(persistence)
        await persistence.hydrate(into: store)
        let before = persistence.database

        let preferences = InMemoryKeyValueStore()
        // The real builder, not a stub: the one an app gets by default.
        let sync = SyncCoordinator<ItemsState, ItemsAction>(
            persistence: persistence, models: models, mode: .localOnly,
            preflight: .mock(entitled: true, account: .available), keyValue: preferences,
            cloudKitContainerID: probeContainerID)

        #expect(await sync.setSyncEnabled(true, into: store) == .unavailableRebuildFailed)
        #expect(sync.mode == .localOnly)
        #expect(preferences.value(.syncMode) == nil, "a toggle that didn't take effect is not remembered")
        #expect(persistence.database === before, "the local database stays active")
        #expect(store.items[id]?.label == "local")
    }
}
