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

    /// Entities in insertion order. The single source of truth for entity data.
    private var entities: [Entity] = []

    /// Maps entity ID → position in `entities` for O(1) keyed access.
    private var positions: [UUID: Int] = [:]

    /// Accumulated changes since the last `resetChanges()` call.
    public private(set) var changes = ChangeSet()

    // MARK: - Init

    /// Creates an empty store.
    public init() {}

    /// Creates a store pre-populated from an array (e.g. hydration).
    /// Does **not** record changes — the data is already persisted.
    public init(_ initialEntities: [Entity]) {
        entities = initialEntities
        for (index, entity) in initialEntities.enumerated() {
            positions[entity.id] = index
        }
    }

    // MARK: - Access

    /// O(1) keyed access. Setting a value records an upsert; setting `nil` records a deletion.
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

    /// Mutates an entity in-place. Records the change only if the value actually changed.
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

    /// All entities in insertion order. O(1) — returns the stored array directly.
    public var values: [Entity] { entities }

    /// Number of entities.
    public var count: Int { entities.count }

    /// Whether the store is empty.
    public var isEmpty: Bool { entities.isEmpty }

    /// Whether an entity with this ID exists.
    public func contains(_ id: UUID) -> Bool { positions[id] != nil }

    // MARK: - Bulk Operations

    /// Sorts the store's order using the given predicate.
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

    /// Removes all entities matching the predicate. Records deletions.
    public mutating func removeAll(where shouldRemove: (Entity) -> Bool) {
        let removedIDs = Set(entities.filter(shouldRemove).map(\.id))
        guard !removedIDs.isEmpty else { return }

        entities.removeAll { removedIDs.contains($0.id) }

        // Rebuild index once
        positions = [:]
        for (i, entity) in entities.enumerated() {
            positions[entity.id] = i
        }

        for id in removedIDs {
            changes.deletions.insert(id)
            changes.upserts.remove(id)
        }
    }

    // MARK: - Change Tracking

    /// Clears the changelog. Called by `StateWriter` after draining.
    public mutating func resetChanges() {
        changes = ChangeSet()
    }

    // MARK: - Merging (Re-hydration)

    /// Merges entities from another store, preferring existing values when the
    /// closure returns `true`.
    ///
    /// Use this for re-hydration scenarios where the database may return partial
    /// data (e.g. metadata-only loading) and you need to preserve richer
    /// in-memory state that was loaded lazily after startup.
    ///
    /// ```swift
    /// var merged = EntityStore(allCampaignsFromDB)
    /// merged.merge(from: existingStore) { existing, incoming in
    ///     existing.calculationState != nil && incoming.calculationState == nil
    /// }
    /// campaigns = merged
    /// ```
    ///
    /// - Parameters:
    ///   - other: The store whose entities should be merged in.
    ///   - preferExisting: Called when an entity with the same ID exists in both
    ///     stores. The first argument is the entity from `other`, the second is
    ///     the entity already in `self`. Return `true` to keep the entity from
    ///     `other`, replacing the one in `self`.
    ///
    /// Does **not** record changes — this is a hydration operation.
    public mutating func merge(
        from other: EntityStore,
        preferExisting: (_ existing: Entity, _ incoming: Entity) -> Bool
    ) {
        for entity in other.values {
            if let index = positions[entity.id] {
                if preferExisting(entity, entities[index]) {
                    entities[index] = entity
                }
                // else: keep self's current value
            } else {
                // Entity only in other — add it
                positions[entity.id] = entities.count
                entities.append(entity)
            }
        }
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
    /// `PersistenceMiddleware` picks them up via normal `afterReduce()` draining.
    public mutating func restore(from source: EntityStore) {
        let currentIDs = Set(positions.keys)
        let sourceIDs = Set(source.positions.keys)

        // Deletions: in current but not in source
        for id in currentIDs.subtracting(sourceIDs) {
            changes.deletions.insert(id)
            changes.upserts.remove(id)
        }

        // Upserts: new or changed entities in source
        for entity in source.entities {
            if let index = positions[entity.id] {
                if entities[index] != entity {
                    changes.upserts.insert(entity.id)
                }
            } else {
                changes.upserts.insert(entity.id)
            }
        }

        // Replace storage
        entities = source.entities
        positions = source.positions
    }

    // MARK: - Equatable

    /// Two stores are equal when they contain the same entities in the same order.
    /// Changes are excluded — they're transient metadata, not semantic state.
    public static func == (lhs: EntityStore, rhs: EntityStore) -> Bool {
        lhs.entities == rhs.entities
    }
}
