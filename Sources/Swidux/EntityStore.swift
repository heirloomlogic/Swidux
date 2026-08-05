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

    /// IDs that ``reconcile(with:preserving:removingMissing:)`` removed because
    /// storage no longer held them — a deletion made on another device.
    ///
    /// ``restore(from:)`` refuses to bring these back, which scopes undo to
    /// locally-originated changes: a snapshot older than the deletion would
    /// otherwise re-add the row as a *creation* and re-seed every peer that had
    /// already agreed it was gone.
    ///
    /// An ID leaves this set the moment it becomes local again — an explicit
    /// write through the subscript, or storage handing the row back on a later
    /// merge — so a row that another device deletes and then restores is
    /// undoable again.
    ///
    /// Survives ``resetChanges()``: a flush ends the write's life, not the
    /// deletion's. The set is bounded by remote deletions per session, and a
    /// first-load hydration replaces the store outright.
    public private(set) var remotelyRemovedIDs: Set<UUID> = []

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
        positions = Dictionary(minimumCapacity: initialEntities.count)
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
                // An explicit local write claims the ID back from a remote
                // deletion — undo may restore it again.
                clearRemoteRemoval(of: id)
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

    /// Who removed the rows, which decides what the removal is recorded as.
    private enum RemovalOrigin {
        /// The local user. Records a deletion to flush, cancelling any pending
        /// upsert.
        case local

        /// Another device, inferred from the row's absence in storage. Records
        /// no deletion — the row is already gone from disk, so flushing one
        /// would echo it straight back as a local write — and lands in
        /// ``remotelyRemovedIDs`` instead.
        case remote
    }

    /// Shared removal tail: one filtering pass over storage, one index rebuild,
    /// and a record per removed ID that depends on who removed it.
    ///
    /// `removedIDs` must contain only IDs currently present in the store.
    private mutating func removeBatch(_ removedIDs: Set<UUID>, origin: RemovalOrigin = .local) {
        guard !removedIDs.isEmpty else { return }

        entities.removeAll { removedIDs.contains($0.id) }

        // Rebuild index once
        positions = Dictionary(minimumCapacity: entities.count)
        for (i, entity) in entities.enumerated() {
            positions[entity.id] = i
        }

        switch origin {
        case .local:
            for id in removedIDs {
                changes.deletions.insert(id)
                changes.upserts.remove(id)
            }
        case .remote:
            remotelyRemovedIDs.formUnion(removedIDs)
        }
    }

    /// Takes `id` back from ``remotelyRemovedIDs`` — it is local again.
    ///
    /// The `contains` check is load-bearing, not a micro-optimisation. Every
    /// insertion path calls this, including the subscript setter on each entity
    /// write and `reconcile` on every remote row of every sync tick, while a
    /// hit is vanishingly rare. `Set.remove` is `mutating` and this buffer is
    /// shared with the observer and with each undo snapshot, so calling it
    /// unconditionally would fault in a copy-on-write copy to accomplish
    /// nothing. A non-mutating lookup does not.
    private mutating func clearRemoteRemoval(of id: UUID) {
        guard remotelyRemovedIDs.contains(id) else { return }
        remotelyRemovedIDs.remove(id)
    }

    // MARK: - Change Tracking

    /// Clears the changelog.
    ///
    /// Called by `StateWriter` after draining. Deliberately leaves
    /// ``remotelyRemovedIDs`` alone: a drain ends the life of a pending *write*,
    /// while a remote deletion has to outlive every undo snapshot taken before
    /// it.
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
                // Storage still holds the row, so it was never deleted.
                clearRemoteRemoval(of: entity.id)
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
        var owned = preserving
        if !changes.upserts.isEmpty { owned.formUnion(changes.upserts) }
        if !changes.deletions.isEmpty { owned.formUnion(changes.deletions) }

        for entity in remote.values where !owned.contains(entity.id) {
            if let index = positions[entity.id] {
                entities[index] = entity
            } else {
                positions[entity.id] = entities.count
                entities.append(entity)
            }
            // Storage holds the row, so any earlier remote deletion of this ID
            // has itself been undone elsewhere. The ID is live again.
            clearRemoteRemoval(of: entity.id)
        }

        guard removingMissing else { return }
        // One pass over the keys we hold, allocating only for what's actually
        // missing — a sync tick that deleted nothing should allocate nothing.
        var missing: Set<UUID> = []
        for id in positions.keys where !remote.contains(id) && !owned.contains(id) {
            missing.insert(id)
        }
        removeBatch(missing, origin: .remote)
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
    ///
    /// Entities in ``remotelyRemovedIDs`` are dropped from `source` first — see
    /// that property for why undo doesn't own them. A store with no remote
    /// deletions, which is every app that doesn't sync, takes an identical path
    /// to before.
    public mutating func restore(from source: EntityStore) {
        guard !remotelyRemovedIDs.isEmpty else {
            return restore(entities: source.entities, positions: source.positions)
        }
        // The initializer already pairs an entity array with its index.
        let kept = EntityStore(source.entities.filter { !remotelyRemovedIDs.contains($0.id) })
        restore(entities: kept.entities, positions: kept.positions)
    }

    /// Records the diff against the snapshot's entities, then adopts them.
    ///
    /// `positions` must be the index of `entities`.
    private mutating func restore(entities snapshot: [Entity], positions snapshotIndex: [UUID: Int]) {
        // Deletions: in current but not in the snapshot
        for id in positions.keys where snapshotIndex[id] == nil {
            changes.deletions.insert(id)
            changes.upserts.remove(id)
        }

        // Upserts: new or changed entities in the snapshot. Restoring an entity
        // cancels any pending deletion for the same ID (later operation wins).
        for entity in snapshot {
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
        entities = snapshot
        positions = snapshotIndex
    }

    // MARK: - Equatable

    /// Two stores are equal when they contain the same entities in the same order.
    ///
    /// Changes and remotely removed IDs are excluded — they're transient
    /// metadata, not semantic state.
    public static func == (lhs: EntityStore, rhs: EntityStore) -> Bool {
        lhs.entities == rhs.entities
    }
}
