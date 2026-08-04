//
//  EntityStore.swift
//  Swidux
//
//  Generic ordered collection of identifiable entities with built-in change tracking.
//

import Foundation

/// An ordered, keyed collection of identifiable entities that silently records
/// every mutation for downstream persistence.
///
/// Behaves like a dictionary (`store[id]`) but preserves insertion order
/// (`store.values`). Every insert, update, and delete is recorded in a
/// `ChangeSet` that the persistence middleware drains after each reducer call.
///
/// Internally uses a single `[Entity]` array for storage with a lightweight
/// `[UUID: Int]` index for O(1) keyed access — no duplicate entity copies.
///
/// ## Usage
///
/// ```swift
/// var cards = EntityStore<Card>()
/// cards[card.id] = card           // insert — recorded
/// cards.modify(card.id) { $0.quote = "Hello" }  // update — recorded
/// cards[card.id] = nil            // delete — recorded
/// ```
public nonisolated struct EntityStore<
    Entity: Identifiable & Equatable & Sendable
>: Sendable, Equatable where Entity.ID == UUID {
    // MARK: - Storage

    /// Entities in insertion order.
    ///
    /// The single source of truth for entity data.
    private var entities: [Entity] = []

    /// Maps entity ID → position in `entities` for O(1) keyed access.
    private var positions: [UUID: Int] = [:]

    /// Accumulated changes since the last `resetChanges()` call.
    public private(set) var changes = ChangeSet()

    // MARK: - Init

    /// Creates an empty store.
    public init() {}

    /// Creates a store pre-populated from an array (e.g. first-load hydration at app launch).
    ///
    /// Does **not** record changes — the data is already persisted.
    ///
    /// > Important: This is **first-load** hydration only. Do not use this initializer
    /// > to "refresh from disk" mid-session by assigning into a live `EntityStore`
    /// > (e.g. `state.items = EntityStore(fetched)` from a CloudKit re-hydrate action).
    /// > In-memory state may hold unflushed writes or live UI bindings; wholesale
    /// > replacement silently drops them and surfaces as lost keystrokes. Use
    /// > ``merge(from:shouldReplace:)`` for that path — it records no changes and
    /// > lets you decide per-ID which side wins. Under `NSPersistentCloudKitContainer`
    /// > the gotcha is especially sharp: `.NSPersistentStoreRemoteChange` fires for
    /// > local saves too, so a naïve "refresh on remote change" observer feeds the
    /// > app its own writes.
    ///
    /// Entities sharing an ID are collapsed to the first occurrence. A store
    /// cannot represent duplicates — `positions` holds one index per ID — and
    /// admitting them corrupts the index: the map would keep only the last
    /// index while the array kept every copy, so `count` over-reports and a
    /// later delete orphans the earlier copy with no `positions` entry at all,
    /// leaving a row that is visible in ``values`` but invisible to
    /// ``contains(_:)`` and the subscript. Persisted rows can legitimately
    /// share an ID (CloudKit forbids unique constraints), so this initializer
    /// has to be total rather than trusting its input.
    public init(_ initialEntities: [Entity]) {
        entities.reserveCapacity(initialEntities.count)
        for entity in initialEntities where positions[entity.id] == nil {
            positions[entity.id] = entities.count
            entities.append(entity)
        }
    }

    // MARK: - Access

    /// O(1) keyed access.
    ///
    /// Setting a value records an upsert; setting `nil` records a deletion.
    ///
    /// Deleting via the subscript shifts the array tail and reindexes the
    /// shifted entries — O(tail) per delete, so k independent subscript
    /// deletes cost O(n·k). For bulk deletion prefer ``remove(ids:)`` or
    /// ``removeAll(where:)``, which do a single pass and one index rebuild.
    public subscript(id: UUID) -> Entity? {
        get {
            guard let index = positions[id] else { return nil }
            return entities[index]
        }
        set {
            if let value = newValue {
                if let index = positions[id] {
                    // Update existing
                    entities[index] = value
                } else {
                    // Insert new
                    positions[id] = entities.count
                    entities.append(value)
                }
                changes.upserts.insert(id)
                // Later operation wins: a reinsert cancels a pending deletion,
                // otherwise the flush would apply the delete after the write.
                changes.deletions.remove(id)
            } else if let index = positions.removeValue(forKey: id) {
                // Delete
                entities.remove(at: index)
                // Reindex entries that shifted down
                for i in index..<entities.count {
                    positions[entities[i].id] = i
                }
                changes.deletions.insert(id)
                changes.upserts.remove(id)
            }
        }
    }

    /// Mutates an entity in-place.
    ///
    /// Records the change only if the value actually changed.
    /// No-op if the ID doesn't exist.
    public mutating func modify(_ id: UUID, _ transform: (inout Entity) -> Void) {
        guard let index = positions[id] else { return }
        let old = entities[index]
        transform(&entities[index])
        if entities[index] != old {
            changes.upserts.insert(id)
        }
    }

    // MARK: - Collection

    /// All entities in insertion order.
    ///
    /// O(1) — returns the stored array directly.
    public var values: [Entity] { entities }

    /// Number of entities.
    public var count: Int { entities.count }

    /// Whether the store is empty.
    public var isEmpty: Bool { entities.isEmpty }

    /// Whether an entity with this ID exists.
    public func contains(_ id: UUID) -> Bool { positions[id] != nil }

    // MARK: - Bulk Operations

    /// Sorts the store's order using the given predicate.
    ///
    /// Only records upserts for entities whose position actually changed.
    public mutating func sort(by areInIncreasingOrder: (Entity, Entity) -> Bool) {
        let oldOrder = entities
        entities.sort(by: areInIncreasingOrder)
        for (index, entity) in entities.enumerated() {
            positions[entity.id] = index
            if index >= oldOrder.count || oldOrder[index].id != entity.id {
                changes.upserts.insert(entity.id)
            }
        }
    }

    /// Removes all entities matching the predicate.
    ///
    /// Records deletions.
    public mutating func removeAll(where shouldRemove: (Entity) -> Bool) {
        removeBatch(Set(entities.filter(shouldRemove).map(\.id)))
    }

    /// Removes the entities with the given IDs in a single pass.
    ///
    /// Each ID actually present records a deletion and cancels any pending
    /// upsert, exactly like `store[id] = nil`. Unknown IDs (and duplicates)
    /// are ignored and record nothing. Survivor order is preserved.
    ///
    /// Prefer this over a subscript loop for bulk deletion: each
    /// `store[id] = nil` shifts the array tail and reindexes (O(tail)), so
    /// k subscript deletes cost O(n·k); this removes everything in one pass
    /// with one index rebuild.
    public mutating func remove(ids: some Sequence<UUID>) {
        removeBatch(Set(ids.filter { positions[$0] != nil }))
    }

    /// Shared removal tail: one filtering pass over storage, one index
    /// rebuild, and a deletion record (cancelling any pending upsert) per
    /// removed ID.
    ///
    /// `removedIDs` must contain only IDs currently present in the store.
    ///
    /// `recordingChanges` is `false` only for hydration-side removals, where
    /// the row is already gone from disk and recording a deletion would echo it
    /// straight back as a local write.
    private mutating func removeBatch(_ removedIDs: Set<UUID>, recordingChanges: Bool = true) {
        guard !removedIDs.isEmpty else { return }

        entities.removeAll { removedIDs.contains($0.id) }

        // Rebuild index once
        positions = [:]
        for (i, entity) in entities.enumerated() {
            positions[entity.id] = i
        }

        guard recordingChanges else { return }
        for id in removedIDs {
            changes.deletions.insert(id)
            changes.upserts.remove(id)
        }
    }

    // MARK: - Change Tracking

    /// Clears the changelog.
    ///
    /// Called by `StateWriter` after draining.
    public mutating func resetChanges() {
        changes = ChangeSet()
    }

    // MARK: - Merging (Re-hydration)

    /// Merges entities from another store. Entities only present in `other`
    /// are always added; for IDs present in both, `shouldReplace` decides
    /// whether the incoming value overwrites the one already in `self`.
    ///
    /// Use this for re-hydration scenarios where the database may return
    /// partial or stale data and you need to preserve richer in-memory state.
    /// `{ _, _ in false }` keeps every current value and only absorbs new rows
    /// (the rule-#8 "prefer in-memory" merge).
    ///
    /// ```swift
    /// // Take the incoming row only when the current one lacks lazy-loaded data.
    /// campaigns.merge(from: EntityStore(fetched)) { current, incoming in
    ///     current.calculationState == nil && incoming.calculationState != nil
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - other: The store whose entities should be merged in.
    ///   - shouldReplace: Called when an entity with the same ID exists in
    ///     both stores. The first argument is the entity already in `self`,
    ///     the second is the incoming entity from `other`. Return `true` to
    ///     replace the current value with the incoming one.
    ///
    /// An ID that is absent from `self` only because it has a pending *local*
    /// deletion (still in `changes.deletions`, not yet flushed to disk) is **not**
    /// re-added: a "refresh from disk" that races an unflushed delete must not
    /// resurrect the entity. The pending deletion is preserved so it still flushes.
    ///
    /// Does **not** record changes — this is a hydration operation.
    public mutating func merge(
        from other: EntityStore,
        shouldReplace: (_ current: Entity, _ incoming: Entity) -> Bool
    ) {
        for entity in other.values {
            if let index = positions[entity.id] {
                if shouldReplace(entities[index], entity) {
                    entities[index] = entity
                }
                // else: keep self's current value
            } else if !changes.deletions.contains(entity.id) {
                // Entity only in other, and not pending local deletion — add it.
                positions[entity.id] = entities.count
                entities.append(entity)
            }
            // else: locally deleted but not yet flushed — do not resurrect.
        }
    }

    /// Reconciles this store against an authoritative snapshot from storage.
    ///
    /// Where ``merge(from:shouldReplace:)`` means *keep everything and absorb
    /// what's new*, this means *storage is authoritative except where you say
    /// otherwise* — which is what lets a remote edit or a remote deletion
    /// surface mid-session instead of waiting for the next launch.
    ///
    /// - Parameters:
    ///   - remote: The rows read from storage.
    ///   - preserving: IDs the caller knows carry unflushed local intent — a
    ///     drained-but-unflushed write, a write whose save failed, or a pending
    ///     deletion. `remote` has no authority over them: they are neither
    ///     overwritten, nor inserted, nor removed. This store's own un-drained
    ///     ``changes`` are folded in automatically, so a pending local deletion
    ///     is never resurrected even when `preserving` is empty.
    ///   - removingMissing: When `true`, IDs held here that are absent from
    ///     `remote` and not preserved are removed — a deletion made on another
    ///     device. When `false` the reconcile is additive: remote edits still
    ///     land, but nothing is ever removed.
    ///
    /// Does **not** record changes — this is a hydration operation, and every
    /// value it writes or removes already reflects what is in storage.
    /// Recording them would echo each remote change straight back as a local
    /// write.
    public mutating func reconcile(
        with remote: EntityStore,
        preserving: Set<UUID>,
        removingMissing: Bool
    ) {
        let owned = preserving.union(changes.upserts).union(changes.deletions)

        for entity in remote.values where !owned.contains(entity.id) {
            if let index = positions[entity.id] {
                entities[index] = entity
            } else {
                positions[entity.id] = entities.count
                entities.append(entity)
            }
        }

        guard removingMissing else { return }
        let remoteIDs = Set(remote.values.map(\.id))
        removeBatch(
            Set(positions.keys).subtracting(remoteIDs).subtracting(owned),
            recordingChanges: false
        )
    }

    // MARK: - Restore (Undo/Redo)

    /// Replaces all entities with those from `source`, recording the
    /// differences as changes for persistence tracking.
    ///
    /// Use this when restoring a previous state snapshot (e.g. undo/redo)
    /// so the persistence middleware can persist the restored state.
    ///
    /// Unlike `merge(from:)` (which is a hydration operation that records
    /// no changes), `restore` records every difference so that
    /// `PersistencePlugin` picks them up via normal `afterReduce()` draining.
    public mutating func restore(from source: EntityStore) {
        let currentIDs = Set(positions.keys)
        let sourceIDs = Set(source.positions.keys)

        // Deletions: in current but not in source
        for id in currentIDs.subtracting(sourceIDs) {
            changes.deletions.insert(id)
            changes.upserts.remove(id)
        }

        // Upserts: new or changed entities in source. Restoring an entity
        // cancels any pending deletion for the same ID (later operation wins).
        for entity in source.entities {
            if let index = positions[entity.id] {
                if entities[index] != entity {
                    changes.upserts.insert(entity.id)
                    changes.deletions.remove(entity.id)
                }
            } else {
                changes.upserts.insert(entity.id)
                changes.deletions.remove(entity.id)
            }
        }

        // Replace storage
        entities = source.entities
        positions = source.positions
    }

    // MARK: - Equatable

    /// Two stores are equal when they contain the same entities in the same order.
    ///
    /// Changes are excluded — they're transient metadata, not semantic state.
    public static func == (lhs: EntityStore, rhs: EntityStore) -> Bool {
        lhs.entities == rhs.entities
    }
}
