//
//  PersistedHistoryTests.swift
//  SwiduxPersistenceTests
//
//  Cover for #72: the generated model's `id` must survive into a delete
//  transaction's tombstone, or a remote deletion can't be identified from
//  history at all. Also pins that nothing *else* is preserved, and that the
//  attribute doesn't force a migration on stores written without it.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Helpers

/// A fresh temp URL. A store left over from an earlier run would carry its
/// transactions with it and every assertion here would be meaningless.
private func temporaryStoreURL(_ prefix: String) -> URL {
    URL.temporaryDirectory.appending(path: "swidux-\(prefix)-\(UUID().uuidString).store")
}

/// An on-disk container, built the way the library builds one.
///
/// On-disk because the migration test below has to close a store and reopen it
/// under a second schema, which needs a real file. History itself does *not*
/// need one — an in-memory container records transactions and tombstones just as
/// well, which is what `HistoryWatermarkTests` runs against. It goes through
/// `ContainerFactory` rather than assembling a `ModelConfiguration` by hand —
/// otherwise these tests would vouch for a container the library doesn't ship.
private func makeOnDiskContainer<M: PersistentModel>(
    _ model: M.Type,
    at url: URL = temporaryStoreURL("history")
) throws -> ModelContainer {
    try ContainerFactory.makeLocalContainer(models: [model], url: url)
}

/// The tombstones of every deletion recorded in the store's history.
///
/// Two unobvious steps, both of which fail quietly rather than loudly.
/// `HistoryChange` is an *enum* — `.insert` / `.update` / `.delete`, each
/// wrapping an existential — so a change can only be recognised by
/// pattern-matching it; casting one to `any HistoryDelete` compiles and always
/// misses. And `any HistoryDelete` hides its `Model` associated type, so
/// `tombstone` won't compile until the primary associated type is bound.
private func recordedTombstones<M: PersistentModel>(
    of type: M.Type,
    in context: ModelContext
) throws -> [HistoryTombstone<M>] {
    try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        .flatMap(\.changes)
        .compactMap { change in
            guard case .delete(let deletion) = change else { return nil }
            return (deletion as? any HistoryDelete<M>)?.tombstone
        }
}

// MARK: - Tombstones

@Suite("Persisted history tombstones")
struct PersistedHistoryTests {
    @Test("a deleted row's id is recoverable from its tombstone")
    func tombstoneCarriesTheIdentity() throws {
        let context = ModelContext(try makeOnDiskContainer(NoteModel.self))
        let id = UUID()
        let row = NoteModel(from: Note(id: id, title: "doomed", pinned: false))

        // Two saves, not one: an insert and a delete in the same transaction
        // collapse, and no deletion reaches history at all.
        context.insert(row)
        try context.save()
        context.delete(row)
        try context.save()

        let tombstone = try #require(
            try recordedTombstones(of: NoteModel.self, in: context).first,
            "the delete must reach persistent history at all")
        // The subscript is untyped — a tombstone is a bag of preserved values,
        // not a partial model — so the cast is part of the assertion.
        #expect(
            tombstone[\.id] as? UUID == id,
            "an empty tombstone leaves the deleted entity unidentifiable"
        )
    }

    @Test("only the identity is preserved — other columns stay out of the tombstone")
    func tombstonePreservesNothingElse() throws {
        let context = ModelContext(try makeOnDiskContainer(NoteModel.self))
        let row = NoteModel(from: Note(id: UUID(), title: "secret", pinned: true))

        context.insert(row)
        try context.save()
        context.delete(row)
        try context.save()

        let tombstone = try #require(
            try recordedTombstones(of: NoteModel.self, in: context).first,
            "the delete must reach persistent history at all")
        // A tombstone is retained history, so it is the one place a "deleted"
        // value outlives the row. Widening it past the identity would quietly
        // turn deletion into retention. Counting rather than naming the other
        // columns means a field added to `Note` later can't slip in unasserted.
        #expect(Array(tombstone).count == 1, "exactly one value is preserved")
        #expect(tombstone[\.id] != nil, "and it is the identity, not a payload column")
    }
}

// MARK: - Migration

/// Twin probes, identical but for the attribute under test.
///
/// Both are named `TombstoneProbe`, so if SwiftData derives its entity name from
/// the bare type name they describe the *same* entity and a store written by one
/// can be reopened by the other — which is exactly the upgrade an existing app
/// performs. `probeEntityNamesMatch` checks that premise before the migration
/// test leans on it.
private enum Legacy {
    @Model
    final class TombstoneProbe {
        var id: UUID = UUID()
        var label: String = ""

        init(id: UUID, label: String) {
            self.id = id
            self.label = label
        }
    }
}

private enum Upgraded {
    @Model
    final class TombstoneProbe {
        @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
        var label: String = ""

        init(id: UUID, label: String) {
            self.id = id
            self.label = label
        }
    }
}

@Suite("preserveValueOnDeletion migration")
struct PreserveValueOnDeletionMigrationTests {
    @Test("the twin probes describe the same SwiftData entity")
    func probeEntityNamesMatch() {
        let legacy = Schema([Legacy.TombstoneProbe.self]).entities.first?.name
        let upgraded = Schema([Upgraded.TombstoneProbe.self]).entities.first?.name
        #expect(legacy == upgraded, "if these differ, the migration test below proves nothing")
    }

    @Test("adding the attribute does not force a migration on an existing store")
    func attributeIsMigrationTransparent() throws {
        let url = temporaryStoreURL("migrate")
        let id = UUID()

        // Written by the old schema, then released so the store is closed.
        do {
            let context = ModelContext(try makeOnDiskContainer(Legacy.TombstoneProbe.self, at: url))
            context.insert(Legacy.TombstoneProbe(id: id, label: "written before the upgrade"))
            try context.save()
        }

        // Reopened by the new schema. No migration plan is supplied on purpose:
        // if the attribute changed the entity's version hash, this throws.
        let context = ModelContext(try makeOnDiskContainer(Upgraded.TombstoneProbe.self, at: url))
        let rows = try context.fetch(FetchDescriptor<Upgraded.TombstoneProbe>())

        #expect(rows.count == 1, "the pre-upgrade row must still be there")
        #expect(rows.first?.id == id)
        #expect(rows.first?.label == "written before the upgrade")
    }
}
