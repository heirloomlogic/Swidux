//
//  AttributedIDs.swift
//  SwiduxPersistence
//
//  Identities keyed by the entity that owns them — the currency a history scan,
//  a merge's scope, and a merge's unfinished business are all counted in.
//

import Foundation

/// Identities keyed by the entity that owns them, split by what a merge should
/// do with each: read the row back, or remove it.
///
/// An entity with nothing in it is **absent**, never present-and-empty. The two
/// are indistinguishable to ``isEmpty``, and an entity named for no rows is read
/// for nothing — which is the saving the keying exists for. Every mutation here
/// preserves that, so no caller has to remember it.
struct AttributedIDs: Sendable {
    /// Rows to read back and reconcile.
    private(set) var changed: [String: Set<UUID>] = [:]

    /// Rows to remove, where policy grants the authority.
    private(set) var deleted: [String: Set<UUID>] = [:]

    /// Whether any entity was named for anything.
    var isEmpty: Bool { changed.isEmpty && deleted.isEmpty }

    /// How many identities are named, across every entity.
    var count: Int {
        changed.values.reduce(0) { $0 + $1.count } + deleted.values.reduce(0) { $0 + $1.count }
    }

    /// The identities `entityName` was told were deleted.
    func deletions(for entityName: String) -> Set<UUID> { deleted[entityName] ?? [] }

    /// Everything `entityName` should read: what it was told changed, plus what
    /// it was told was deleted. Declared deletions are read too — a row storage
    /// still holds is what refutes a stale tombstone, and only a fetch can tell
    /// us that.
    func reading(for entityName: String) -> Set<UUID> {
        guard let changed = changed[entityName] else { return deletions(for: entityName) }
        guard let deleted = deleted[entityName] else { return changed }
        return changed.union(deleted)
    }

    /// Names `ids` as changed under `entityName`.
    mutating func insert(changed ids: Set<UUID>, for entityName: String) {
        Self.insert(ids, into: &changed, for: entityName)
    }

    /// Names `ids` as deleted under `entityName`.
    mutating func insert(deleted ids: Set<UUID>, for entityName: String) {
        Self.insert(ids, into: &deleted, for: entityName)
    }

    /// Records one entity's unfinished business, under the name a history scan
    /// groups by.
    mutating func record(_ withheld: Withheld, for entityName: String) {
        insert(changed: withheld.changed, for: entityName)
        insert(deleted: withheld.deleted, for: entityName)
    }

    /// Folds `other` in, entity by entity.
    mutating func formUnion(_ other: AttributedIDs) {
        for (entityName, ids) in other.changed { insert(changed: ids, for: entityName) }
        for (entityName, ids) in other.deleted { insert(deleted: ids, for: entityName) }
    }

    /// The one writer, so the absent-not-empty invariant has one place to hold.
    ///
    /// A new key adopts `ids` outright rather than hashing every element into a
    /// fresh set that would only replace it — which is the common case here,
    /// since both the scan and the carry-over build into an empty value.
    private static func insert(
        _ ids: Set<UUID>, into groups: inout [String: Set<UUID>], for entityName: String
    ) {
        guard !ids.isEmpty else { return }
        if groups[entityName] == nil {
            groups[entityName] = ids
        } else {
            groups[entityName]?.formUnion(ids)
        }
    }
}

/// One entity's rows that a merge read but declined to apply.
///
/// Split by what the merge was told rather than by what it found. A withheld
/// *change* is re-offered by reading the row again; a withheld *deletion* has no
/// row left to read and has to be re-declared. Collapsing the two into one set
/// of identities would turn every deferred deletion into a fetch that finds
/// nothing and concludes nothing.
struct Withheld: Sendable {
    /// Rows storage holds a value for that the merge did not take.
    var changed: Set<UUID> = []

    /// Rows storage no longer holds that the merge did not remove.
    var deleted: Set<UUID> = []

    var isEmpty: Bool { changed.isEmpty && deleted.isEmpty }

    /// Every identity withheld. Reporting cares that a row was deferred, not
    /// which way — and a tick almost never defers both ways at once, so this
    /// usually hands back a set that already exists.
    var ids: Set<UUID> {
        if changed.isEmpty { return deleted }
        if deleted.isEmpty { return changed }
        return changed.union(deleted)
    }
}
