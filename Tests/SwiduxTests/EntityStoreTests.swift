//
//  EntityStoreTests.swift
//  SwiduxTests
//

import Foundation
import Testing

@testable import Swidux

@Suite("EntityStore")
struct EntityStoreTests {
    // MARK: - Init

    @Test("Empty init creates an empty store")
    func emptyInit() {
        let store = EntityStore<TestEntity>()
        #expect(store.count == 0)
        #expect(store.isEmpty)
        #expect(store.values.isEmpty)
        #expect(store.changes.isEmpty)
    }

    @Test("Init from array hydrates without recording changes")
    func hydrationInit() {
        let a = TestEntity(name: "A")
        let b = TestEntity(name: "B")
        let store = EntityStore([a, b])

        #expect(store.count == 2)
        #expect(store[a.id]?.name == "A")
        #expect(store[b.id]?.name == "B")
        // Hydration must NOT record changes
        #expect(store.changes.isEmpty)
        // Preserves insertion order
        #expect(store.values == [a, b])
    }

    @Test("Init collapses entities sharing an ID, keeping the first")
    func hydrationInitCollapsesDuplicates() {
        let id = UUID()
        let first = TestEntity(id: id, name: "first")
        let second = TestEntity(id: id, name: "second")
        let other = TestEntity(name: "other")

        let store = EntityStore([first, second, other])

        // A store holds one entity per ID; admitting both would leave `count`
        // over-reporting and the index out of step with storage.
        #expect(store.count == 2)
        #expect(store.values == [first, other])
        #expect(store[id]?.name == "first")
        #expect(store.contains(id))
        #expect(store.changes.isEmpty)
    }

    @Test("Deleting an ID that arrived duplicated leaves no orphaned row")
    func deleteAfterDuplicateHydration() {
        let id = UUID()
        let other = TestEntity(name: "other")
        var store = EntityStore([TestEntity(id: id, name: "first"), TestEntity(id: id, name: "second"), other])

        store[id] = nil

        // The regression: when both copies were admitted, the delete removed
        // the last and reindexed from there, orphaning the first with no
        // `positions` entry — visible in `values`, invisible to `contains`,
        // undeletable, and re-flushed forever.
        #expect(store.count == 1)
        #expect(store.values == [other])
        #expect(!store.contains(id))
        #expect(store[id] == nil)
    }

    // MARK: - Reconcile

    @Test("reconcile replaces a conflicting value that is not preserved")
    func reconcileReplacesUnownedConflict() {
        let id = UUID()
        var store = EntityStore([TestEntity(id: id, name: "local")])
        store.resetChanges()

        store.reconcile(
            with: EntityStore([TestEntity(id: id, name: "remote")]),
            preserving: [], removingMissing: false)

        #expect(store[id]?.name == "remote")
        #expect(store.changes.isEmpty, "a reconcile must not echo storage back as a local write")
    }

    @Test("reconcile keeps a conflicting value that is preserved")
    func reconcileKeepsOwnedConflict() {
        let id = UUID()
        var store = EntityStore([TestEntity(id: id, name: "local")])
        store.resetChanges()

        store.reconcile(
            with: EntityStore([TestEntity(id: id, name: "remote")]),
            preserving: [id], removingMissing: true)

        #expect(store[id]?.name == "local")
    }

    @Test("reconcile inserts remote-only rows but skips preserved IDs")
    func reconcileInsertsRemoteOnly() {
        let fresh = TestEntity(name: "fresh")
        let pendingDelete = TestEntity(name: "pending delete")
        var store = EntityStore<TestEntity>()

        store.reconcile(
            with: EntityStore([fresh, pendingDelete]),
            preserving: [pendingDelete.id], removingMissing: false)

        #expect(store[fresh.id] == fresh)
        #expect(store[pendingDelete.id] == nil, "storage has no authority over a preserved ID, insert included")
    }

    @Test("reconcile honours an un-drained local deletion even when preserving is empty")
    func reconcileHonoursUndrainedDeletion() {
        let entity = TestEntity(name: "deleted locally")
        var store = EntityStore([entity])
        store.resetChanges()
        store[entity.id] = nil  // un-drained: still in `changes.deletions`

        store.reconcile(
            with: EntityStore([entity]), preserving: [], removingMissing: false)

        #expect(store[entity.id] == nil, "a pending local deletion must never be resurrected")
        #expect(store.changes.deletions.contains(entity.id), "and it must still flush")
    }

    @Test("reconcile removes a missing row and records no deletion for it")
    func reconcileRemovesMissing() {
        let gone = TestEntity(name: "deleted remotely")
        let kept = TestEntity(name: "kept")
        var store = EntityStore([gone, kept])
        store.resetChanges()

        store.reconcile(with: EntityStore([kept]), preserving: [], removingMissing: true)

        #expect(store[gone.id] == nil)
        #expect(store.values == [kept])
        #expect(
            store.changes.isEmpty,
            "the row is already gone from storage — recording a deletion would echo it back as a local one"
        )
    }

    @Test("reconcile does not remove a preserved row that is missing from storage")
    func reconcileKeepsPreservedMissing() {
        let local = TestEntity(name: "created locally, not yet flushed")
        var store = EntityStore([local])
        store.resetChanges()

        store.reconcile(with: EntityStore<TestEntity>([]), preserving: [local.id], removingMissing: true)

        #expect(store[local.id] == local)
    }

    @Test("reconcile with removingMissing false leaves memory-only rows alone")
    func reconcileAdditiveKeepsMissing() {
        let local = TestEntity(name: "local")
        var store = EntityStore([local])
        store.resetChanges()

        store.reconcile(with: EntityStore<TestEntity>([]), preserving: [], removingMissing: false)

        #expect(store[local.id] == local)
    }

    @Test("reconcile preserves survivor order and appends remote-only rows at the tail")
    func reconcilePreservesOrder() {
        let a = TestEntity(name: "a")
        let b = TestEntity(name: "b")
        let c = TestEntity(name: "c")
        let newcomer = TestEntity(name: "newcomer")
        var store = EntityStore([a, b, c])
        store.resetChanges()

        store.reconcile(
            with: EntityStore([c, a, newcomer]), preserving: [], removingMissing: true)

        #expect(store.values.map(\.name) == ["a", "c", "newcomer"])
    }

    // MARK: - Subscript

    @Test("Subscript set inserts and records upsert")
    func subscriptInsert() {
        var store = EntityStore<TestEntity>()
        let entity = TestEntity(name: "New")
        store[entity.id] = entity

        #expect(store[entity.id] == entity)
        #expect(store.count == 1)
        #expect(store.changes.upserts.contains(entity.id))
        #expect(store.changes.deletions.isEmpty)
    }

    @Test("Subscript set overwrites existing entity")
    func subscriptUpdate() {
        let id = UUID()
        var store = EntityStore<TestEntity>()
        store[id] = TestEntity(id: id, name: "Original")
        store.resetChanges()

        store[id] = TestEntity(id: id, name: "Updated")

        #expect(store[id]?.name == "Updated")
        #expect(store.count == 1)  // no duplicate
        #expect(store.changes.upserts.contains(id))
    }

    @Test("Subscript get returns nil for missing ID")
    func subscriptGetMissing() {
        let store = EntityStore<TestEntity>()
        #expect(store[UUID()] == nil)
    }

    @Test("Subscript set nil deletes and records deletion")
    func subscriptDelete() {
        let entity = TestEntity(name: "Doomed")
        var store = EntityStore([entity])
        store.resetChanges()

        store[entity.id] = nil

        #expect(store[entity.id] == nil)
        #expect(store.count == 0)
        #expect(store.changes.deletions.contains(entity.id))
    }

    @Test("Deleting an entity removes it from pending upserts")
    func deleteRemovesPendingUpsert() {
        var store = EntityStore<TestEntity>()
        let entity = TestEntity(name: "Ephemeral")
        store[entity.id] = entity
        // At this point the entity is in upserts
        #expect(store.changes.upserts.contains(entity.id))

        store[entity.id] = nil
        // After delete, it should be ONLY in deletions, not upserts
        #expect(!store.changes.upserts.contains(entity.id))
        #expect(store.changes.deletions.contains(entity.id))
    }

    @Test("Subscript set nil for non-existent ID is a no-op")
    func subscriptDeleteMissing() {
        var store = EntityStore<TestEntity>()
        let bogus = UUID()
        store[bogus] = nil

        #expect(store.count == 0)
        #expect(store.changes.isEmpty)
    }

    // MARK: - Modify

    @Test("Modify mutates in-place and records upsert")
    func modifyRecordsUpsert() {
        let entity = TestEntity(name: "Before")
        var store = EntityStore([entity])
        store.resetChanges()

        store.modify(entity.id) { $0.name = "After" }

        #expect(store[entity.id]?.name == "After")
        #expect(store.changes.upserts.contains(entity.id))
    }

    @Test("Modify with no actual change does not record upsert")
    func modifyNoChange() {
        let entity = TestEntity(name: "Same")
        var store = EntityStore([entity])
        store.resetChanges()

        store.modify(entity.id) { _ in
            // no mutation
        }

        #expect(store[entity.id]?.name == "Same")
        #expect(store.changes.isEmpty)
    }

    @Test("Modify for missing ID is a no-op")
    func modifyMissing() {
        var store = EntityStore<TestEntity>()
        store.modify(UUID()) { $0.name = "Nope" }

        #expect(store.isEmpty)
        #expect(store.changes.isEmpty)
    }

    // MARK: - Collection

    @Test("Values preserves insertion order")
    func valuesOrder() {
        var store = EntityStore<TestEntity>()
        let a = TestEntity(name: "A")
        let b = TestEntity(name: "B")
        let c = TestEntity(name: "C")
        store[a.id] = a
        store[b.id] = b
        store[c.id] = c

        #expect(store.values == [a, b, c])
    }

    @Test("Contains returns correct results")
    func containsCheck() {
        let entity = TestEntity()
        let store = EntityStore([entity])

        #expect(store.contains(entity.id))
        #expect(!store.contains(UUID()))
    }

    // MARK: - Bulk Operations

    @Test("Sort reorders entities and records upserts for moved entities")
    func sortReorders() {
        let a = TestEntity(name: "Banana")
        let b = TestEntity(name: "Apple")
        var store = EntityStore([a, b])
        store.resetChanges()

        store.sort { $0.name < $1.name }

        #expect(store.values.map(\.name) == ["Apple", "Banana"])
        // Both moved — both should be upserted
        #expect(store.changes.upserts.contains(a.id))
        #expect(store.changes.upserts.contains(b.id))
    }

    @Test("Sort on already-sorted data records no upserts")
    func sortAlreadySorted() {
        let a = TestEntity(name: "Apple")
        let b = TestEntity(name: "Banana")
        var store = EntityStore([a, b])
        store.resetChanges()

        store.sort { $0.name < $1.name }

        #expect(store.values.map(\.name) == ["Apple", "Banana"])
        // No entities moved — no upserts should be recorded
        #expect(store.changes.isEmpty)
    }

    @Test("RemoveAll removes matching and records deletions")
    func removeAllMatching() {
        let a = TestEntity(name: "keep")
        let b = TestEntity(name: "remove")
        let c = TestEntity(name: "remove")
        var store = EntityStore([a, b, c])
        store.resetChanges()

        store.removeAll { $0.name == "remove" }

        #expect(store.count == 1)
        #expect(store.values == [a])
        #expect(store.changes.deletions.contains(b.id))
        #expect(store.changes.deletions.contains(c.id))
    }

    @Test("Remove(ids:) removes entities and records deletions")
    func removeIDsRecordsDeletions() {
        let a = TestEntity(name: "keep")
        let b = TestEntity(name: "remove")
        let c = TestEntity(name: "remove")
        var store = EntityStore([a, b, c])
        store.resetChanges()

        store.remove(ids: [b.id, c.id])

        #expect(store.count == 1)
        #expect(store.values == [a])
        #expect(store.changes.deletions == [b.id, c.id])
        #expect(store.changes.upserts.isEmpty)
    }

    @Test("Remove(ids:) ignores unknown IDs and records nothing for them")
    func removeIDsUnknownIsNoOp() {
        let a = TestEntity(name: "keep")
        var store = EntityStore([a])
        store.resetChanges()

        store.remove(ids: [UUID(), UUID()])

        #expect(store.count == 1)
        #expect(store.values == [a])
        #expect(store.changes.isEmpty)
    }

    @Test("Remove(ids:) cancels pending upserts for removed entities")
    func removeIDsCancelsPendingUpserts() {
        var store = EntityStore<TestEntity>()
        let entity = TestEntity(name: "Ephemeral")
        store[entity.id] = entity
        #expect(store.changes.upserts.contains(entity.id))

        store.remove(ids: [entity.id])

        // After removal, ONLY in deletions — not upserts.
        #expect(!store.changes.upserts.contains(entity.id))
        #expect(store.changes.deletions.contains(entity.id))
    }

    @Test("Remove(ids:) preserves survivor order")
    func removeIDsPreservesOrder() {
        let a = TestEntity(name: "A")
        let b = TestEntity(name: "B")
        let c = TestEntity(name: "C")
        let d = TestEntity(name: "D")
        var store = EntityStore([a, b, c, d])
        store.resetChanges()

        store.remove(ids: [b.id, d.id])

        #expect(store.values == [a, c])
        // Index still consistent after the rebuild.
        #expect(store[a.id] == a)
        #expect(store[c.id] == c)
    }

    @Test("Remove(ids:) with an empty sequence is a total no-op")
    func removeIDsEmptySequence() {
        let a = TestEntity(name: "keep")
        var store = EntityStore([a])
        store.resetChanges()

        store.remove(ids: [])

        #expect(store.values == [a])
        #expect(store.changes.isEmpty)
    }

    @Test("Remove(ids:) handles duplicate IDs in the input")
    func removeIDsDuplicates() {
        let a = TestEntity(name: "keep")
        let b = TestEntity(name: "remove")
        var store = EntityStore([a, b])
        store.resetChanges()

        store.remove(ids: [b.id, b.id, b.id])

        #expect(store.count == 1)
        #expect(store.values == [a])
        #expect(store.changes.deletions == [b.id])
    }

    // MARK: - Change Tracking

    @Test("ResetChanges clears the changelog")
    func resetChangesClearsLog() {
        var store = EntityStore<TestEntity>()
        let entity = TestEntity()
        store[entity.id] = entity
        #expect(!store.changes.isEmpty)

        store.resetChanges()
        #expect(store.changes.isEmpty)
    }

    // MARK: - Equatable

    @Test("Equatable ignores changes — same data is equal")
    func equatableIgnoresChanges() {
        let entity = TestEntity(name: "same")
        let a = EntityStore([entity])
        var b = EntityStore([entity])

        // a has no changes (hydrated), b has upsert changes
        b.resetChanges()
        b[entity.id] = entity  // records an upsert in b

        #expect(a == b)  // changes are excluded from equality
    }

    @Test("Different data is not equal")
    func notEqual() {
        let a = EntityStore([TestEntity(name: "A")])
        let b = EntityStore([TestEntity(name: "B")])
        #expect(a != b)
    }

    // MARK: - Merge

    @Test("Merge replaces the current entity when shouldReplace returns true")
    func mergeReplacesCurrent() {
        let id = UUID()
        let current = TestEntity(id: id, name: "Current")
        let incoming = TestEntity(id: id, name: "Incoming")

        var store = EntityStore([current])
        let other = EntityStore([incoming])

        store.merge(from: other) { current, incoming in
            current.name == "Current" && incoming.name == "Incoming"
        }

        #expect(store[id]?.name == "Incoming")
        #expect(store.count == 1)
    }

    @Test("Merge keeps the current entity when shouldReplace returns false")
    func mergeKeepsCurrent() {
        let id = UUID()
        let current = TestEntity(id: id, name: "Current")
        let incoming = TestEntity(id: id, name: "Incoming")

        var store = EntityStore([current])
        let other = EntityStore([incoming])

        store.merge(from: other) { _, _ in false }

        #expect(store[id]?.name == "Current")
    }

    @Test("Merge adds entities only present in the other store")
    func mergeAddsNewEntities() {
        let a = TestEntity(name: "A")
        let b = TestEntity(name: "B")

        var store = EntityStore([a])
        let other = EntityStore([b])

        store.merge(from: other) { _, _ in false }

        #expect(store.count == 2)
        #expect(store[a.id] != nil)
        #expect(store[b.id] != nil)
    }

    @Test("Merge does not resurrect an entity with a pending local deletion")
    func mergeDoesNotResurrectPendingDeletion() {
        let a = TestEntity(name: "A")
        let doomed = TestEntity(name: "Doomed")

        // Both exist on disk; the user deletes `doomed` in memory but the delete
        // has not flushed yet (still in `changes.deletions`).
        var store = EntityStore([a, doomed])
        store.resetChanges()
        store[doomed.id] = nil
        #expect(store.changes.deletions.contains(doomed.id))

        // A remote-change refresh fetches the still-present disk rows and merges.
        let disk = EntityStore([a, doomed])
        store.merge(from: disk) { _, _ in false }

        // The delete must survive — no zombie, and the deletion still pending.
        #expect(store[doomed.id] == nil)
        #expect(store.count == 1)
        #expect(store.changes.deletions.contains(doomed.id))
    }

    // MARK: - Restore (Undo/Redo)

    @Test("Restore records upserts for changed entities")
    func restoreRecordsUpserts() {
        let id = UUID()
        let original = TestEntity(id: id, name: "Original")
        let modified = TestEntity(id: id, name: "Modified")

        var store = EntityStore([modified])
        store.resetChanges()

        let snapshot = EntityStore([original])
        store.restore(from: snapshot)

        #expect(store[id]?.name == "Original")
        #expect(store.changes.upserts.contains(id))
        #expect(store.changes.deletions.isEmpty)
    }

    @Test("Restore records deletions for removed entities")
    func restoreRecordsDeletions() {
        let entity = TestEntity(name: "WillBeGone")
        var store = EntityStore([entity])
        store.resetChanges()

        let emptySnapshot = EntityStore<TestEntity>()
        store.restore(from: emptySnapshot)

        #expect(store.isEmpty)
        #expect(store.changes.deletions.contains(entity.id))
    }

    @Test("Restore records upserts for new entities")
    func restoreRecordsNewEntities() {
        var store = EntityStore<TestEntity>()
        store.resetChanges()

        let entity = TestEntity(name: "New")
        let snapshot = EntityStore([entity])
        store.restore(from: snapshot)

        #expect(store[entity.id]?.name == "New")
        #expect(store.changes.upserts.contains(entity.id))
    }

    @Test("Restore with identical data records no changes")
    func restoreIdenticalNoChanges() {
        let entity = TestEntity(name: "Same")
        var store = EntityStore([entity])
        store.resetChanges()

        let snapshot = EntityStore([entity])
        store.restore(from: snapshot)

        #expect(store.changes.isEmpty)
    }

    @Test("Restore handles mixed adds, removes, and changes")
    func restoreMixed() {
        let kept = TestEntity(name: "Kept")
        let removed = TestEntity(name: "Removed")
        let changedID = UUID()
        let changed = TestEntity(id: changedID, name: "Before")

        var store = EntityStore([kept, removed, changed])
        store.resetChanges()

        let added = TestEntity(name: "Added")
        let changedAfter = TestEntity(id: changedID, name: "After")
        let snapshot = EntityStore([kept, changedAfter, added])
        store.restore(from: snapshot)

        #expect(store.count == 3)
        #expect(store[kept.id] != nil)
        #expect(store[removed.id] == nil)
        #expect(store[changedID]?.name == "After")
        #expect(store[added.id] != nil)

        #expect(store.changes.deletions.contains(removed.id))
        #expect(store.changes.upserts.contains(changedID))
        #expect(store.changes.upserts.contains(added.id))
        #expect(!store.changes.upserts.contains(kept.id))
    }

    @Test("Merge does not record changes — hydration semantics")
    func mergeNoChangesRecorded() {
        let a = TestEntity(name: "A")
        let b = TestEntity(name: "B")

        var store = EntityStore([a])
        let other = EntityStore([b])

        store.merge(from: other) { _, _ in false }

        // Merge is a hydration operation — no changelog
        #expect(store.changes.isEmpty)
    }

    // MARK: - Delete/Reinsert Coalescing

    @Test("Reinsert after delete cancels the pending deletion")
    func reinsertAfterDeleteCancelsDeletion() {
        var store = EntityStore<TestEntity>()
        let entity = TestEntity(name: "A")
        store[entity.id] = entity
        store.resetChanges()

        store[entity.id] = nil
        store[entity.id] = entity

        // Later operation wins: the reinsert must cancel the deletion, or the
        // flush batch would carry both and the delete would win at the database.
        #expect(store.changes.upserts.contains(entity.id))
        #expect(!store.changes.deletions.contains(entity.id))
    }

    @Test("restore cancels a pending deletion for a restored entity")
    func restoreCancelsPendingDeletion() {
        var store = EntityStore<TestEntity>()
        let entity = TestEntity(name: "A")
        store[entity.id] = entity
        let snapshot = store
        store.resetChanges()

        store[entity.id] = nil
        store.restore(from: snapshot)

        #expect(store.changes.upserts.contains(entity.id))
        #expect(!store.changes.deletions.contains(entity.id))
    }
}
