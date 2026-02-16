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

    /// Keyed storage for O(1) lookup.
    private var storage: [UUID: Entity] = [:]

    /// Insertion-ordered keys for stable iteration.
    private var order: [UUID] = []

    /// Accumulated changes since the last `resetChanges()` call.
    public private(set) var changes = ChangeSet()

    // MARK: - Init

    /// Creates an empty store.
    public init() {}

    /// Creates a store pre-populated from an array (e.g. hydration).
    /// Does **not** record changes — the data is already persisted.
    public init(_ entities: [Entity]) {
        for entity in entities {
            storage[entity.id] = entity
            order.append(entity.id)
        }
    }

    // MARK: - Access

    /// O(1) keyed access. Setting a value records an upsert; setting `nil` records a deletion.
    public subscript(id: UUID) -> Entity? {
        get { storage[id] }
        set {
            if let value = newValue {
                if storage[id] == nil {
                    order.append(id)
                }
                storage[id] = value
                changes.upserts.insert(id)
            } else if storage.removeValue(forKey: id) != nil {
                order.removeAll { $0 == id }
                changes.deletions.insert(id)
                changes.upserts.remove(id)
            }
        }
    }

    /// Mutates an entity in-place. Records the change. No-op if the ID doesn't exist.
    public mutating func modify(_ id: UUID, _ transform: (inout Entity) -> Void) {
        guard var entity = storage[id] else { return }
        transform(&entity)
        storage[id] = entity
        changes.upserts.insert(id)
    }

    // MARK: - Collection

    /// All entities in insertion order.
    public var values: [Entity] { order.compactMap { storage[$0] } }

    /// Number of entities.
    public var count: Int { storage.count }

    /// Whether the store is empty.
    public var isEmpty: Bool { storage.isEmpty }

    /// Whether an entity with this ID exists.
    public func contains(_ id: UUID) -> Bool { storage[id] != nil }

    // MARK: - Bulk Operations

    /// Sorts the store's order using the given predicate.
    /// Records all reordered entities as upserts (their `sortIndex` likely changed).
    public mutating func sort(by areInIncreasingOrder: (Entity, Entity) -> Bool) {
        let sorted = values.sorted(by: areInIncreasingOrder)
        order = sorted.map(\.id)
    }

    /// Removes all entities matching the predicate. Records deletions.
    public mutating func removeAll(where shouldRemove: (Entity) -> Bool) {
        let toRemove = storage.values.filter(shouldRemove)
        for entity in toRemove {
            self[entity.id] = nil
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
            if let existing = storage[entity.id] {
                if preferExisting(entity, existing) {
                    storage[entity.id] = entity
                }
                // else: keep self's current value
            } else {
                // Entity only in other — add it
                storage[entity.id] = entity
                order.append(entity.id)
            }
        }
    }

    // MARK: - Equatable

    /// Two stores are equal when they contain the same entities in the same order.
    /// Changes are excluded — they're transient metadata, not semantic state.
    public static func == (lhs: EntityStore, rhs: EntityStore) -> Bool {
        lhs.order == rhs.order && lhs.storage == rhs.storage
    }
}
