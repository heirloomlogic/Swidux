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

    @Test("Merge keeps existing entity when preferExisting returns true")
    func mergeKeepsExisting() {
        let id = UUID()
        let rich = TestEntity(id: id, name: "Rich")
        let sparse = TestEntity(id: id, name: "Sparse")

        var store = EntityStore([sparse])
        let other = EntityStore([rich])

        store.merge(from: other) { existing, _ in
            existing.name == "Rich"
        }

        #expect(store[id]?.name == "Rich")
        #expect(store.count == 1)
    }

    @Test("Merge accepts incoming when preferExisting returns false")
    func mergeAcceptsIncoming() {
        let id = UUID()
        let existing = TestEntity(id: id, name: "Existing")
        let incoming = TestEntity(id: id, name: "Incoming")

        var store = EntityStore([incoming])
        let other = EntityStore([existing])

        store.merge(from: other) { _, _ in false }

        // When preferExisting returns false, self retains its value
        #expect(store[id]?.name == "Incoming")
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
}
