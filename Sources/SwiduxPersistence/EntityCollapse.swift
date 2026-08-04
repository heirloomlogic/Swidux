//
//  EntityCollapse.swift
//  SwiduxPersistence
//
//  The opt-in hook for removing duplicate rows that CloudKit's lack of unique
//  constraints makes possible, plus a ready-made resolver for the common case.
//

import Foundation

/// What a collapse pass changed on disk.
public struct CollapseOutcome<Entity: Sendable>: Sendable {
    /// The rows that remain, in the order the resolver returned them.
    public let survivors: [Entity]

    /// IDs that were on disk before the pass and are gone after it.
    public let removedIDs: Set<UUID>

    /// Creates an outcome from a collapse pass.
    public init(survivors: [Entity], removedIDs: Set<UUID>) {
        self.survivors = survivors
        self.removedIDs = removedIDs
    }
}

/// Ready-made collapse resolvers.
///
/// ## Why the hook takes the whole collection
///
/// A per-ID resolver would only handle half the problem. Rows sharing an `id`
/// are one failure mode; the other is a **singleton** — an entity an app holds
/// exactly one of, such as a settings record. Created independently on two
/// fresh installs, two singletons have *different* UUIDs, so nothing groups
/// them and no ID-keyed resolver can ever see the conflict. A
/// `([E]) -> [E]` hook covers both, plus general garbage collection, with one
/// API.
///
/// ## The determinism requirement
///
/// A resolver must be a pure function of **replicated content** — never
/// `persistentModelID`, never a local timestamp, never array position. Every
/// device must compute the same survivor set from the same rows. A resolver
/// that doesn't reintroduces the mutual-tombstone loss the write path is
/// designed to avoid: two devices pick different survivors, each tombstones the
/// other's, and after sync *both* rows are gone.
///
/// It must also be idempotent — `collapse(collapse(rows))` must keep the same
/// IDs as `collapse(rows)`. This is checked with an `assert` in debug builds.
///
/// ## Collapse removes IDs, not rows
///
/// A resolver's output is read as *the set of IDs that should exist and what
/// each should contain*. An ID the resolver drops is deleted, including every
/// row carrying it. Several rows that share a **surviving** ID are all updated
/// to the survivor's value, and none of them is deleted.
///
/// That asymmetry is deliberate, and it is the whole reason the singleton case
/// is the one this hook really solves. Deleting an ID is safe because `id` is
/// replicated: every device independently computes the same set of doomed IDs
/// and issues the same deletions. Deleting one of several rows that share an ID
/// is *not* safe — nothing replicated distinguishes them, so two devices can
/// pick different physical rows to keep, each tombstones the other's, and both
/// are lost.
///
/// Rows sharing an ID need no deletion anyway: writes already converge across
/// every matching row and reads already collapse to one value per ID (see
/// ``EntityDB``), so duplicates cost storage and nothing else.
public enum EntityCollapse {
    /// Collapses rows sharing an `id` down to one, keeping the winner of
    /// `choose`. Rows with unique IDs pass through untouched.
    ///
    /// ```swift
    /// .entity(\.cards, collapse: EntityCollapse.byID { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
    /// ```
    ///
    /// - Parameter choose: Picks between two rows sharing an ID. Must be
    ///   commutative and associative, and must decide from replicated content
    ///   only — otherwise devices disagree on the winner.
    /// - Returns: A resolver suitable for ``PersistedEntity/entity(_:collapse:)``.
    public static func byID<E: PersistableEntity>(
        preferring choose: @escaping @Sendable (E, E) -> E
    ) -> @Sendable ([E]) -> [E] {
        { rows in
            var winners: [UUID: E] = [:]
            var order: [UUID] = []
            for row in rows {
                if let current = winners[row.id] {
                    winners[row.id] = choose(current, row)
                } else {
                    winners[row.id] = row
                    order.append(row.id)
                }
            }
            return order.compactMap { winners[$0] }
        }
    }
}
