//
//  PersistedEntity.swift
//  SwiduxPersistence
//
//  App-facing registration that binds an `EntityStore` keypath to its entity
//  type and synthesizes the `StateWriter`, first-load hydration, and the
//  merge-based re-hydration. The app writes no `StateWriter` body, no DB actor.
//

import Foundation
import Swidux
import SwiftData

/// One registered entity collection within a ``PersistenceCoordinator``.
///
/// Build with ``entity(_:policy:collapse:)`` and pass the array to the
/// coordinator. Re-hydration reconciles rather than replaces, and every ID with
/// unflushed local intent is exempt from it, so a "refresh from disk" can never
/// clobber pending writes or live UI edits (rule #8).
///
/// ## Two-phase reads
///
/// Both read paths are split into an **async phase that touches no state** and
/// a **synchronous phase that folds the fetched rows in**. The async half
/// returns the synchronous half as a closure, which keeps the entity type
/// concrete — `PersistedEntity` is generic over `State`, not over `E`, so an
/// explicit result type would need an existential box and a downcast.
///
/// The split is what lets ``PersistenceCoordinator`` read into a live `Store`
/// safely: every fetch completes first, then one suspension-free step packs a
/// fresh snapshot, applies, and unpacks. Holding `inout State` across the fetch
/// instead — the shape this replaces — silently drops whatever was dispatched
/// while the fetch was in flight.
public struct PersistedEntity<State> {
    /// The synchronous second half of a read: folds already-fetched rows into
    /// state. Evaluated against whatever state it is handed, so a caller can
    /// pack a fresh snapshot *after* every fetch has completed.
    typealias Apply = @MainActor (inout State) -> Void

    /// The synchronous second half of a *merge*, which additionally needs the
    /// resolved policy and the set of IDs storage has no authority over. Both
    /// are computed after the fetch, so a write that landed during it counts.
    typealias MergeApply = @MainActor (inout State, MergeContext) -> Void

    let makeWriter: @MainActor (DatabaseHandle, @escaping PersistenceFailureHandler) -> StateWriter<State>

    /// A per-entity narrowing of the coordinator's merge policy, if any.
    let policy: MergePolicy?

    /// IDs whose last save failed — memory and storage disagree, and nothing
    /// else records it.
    let unpersisted: UnpersistedIDs

    /// Phase 1 of first-load hydration: reads the database, touches no state.
    let readForHydrate: @MainActor (DatabaseHandle, PersistenceFailureHandler) async -> Apply

    /// Phase 1 of re-hydration: reads the database, touches no state.
    let readForMerge: @MainActor (DatabaseHandle, PersistenceFailureHandler) async -> MergeApply

    /// Runs the registered collapse against disk, if any, and returns the fold
    /// that removes the losers from live state.
    let collapseOnDisk: @MainActor (DatabaseHandle, PersistenceFailureHandler) async -> Apply

    /// Registers the `EntityStore<E>` at `keyPath` for persistence.
    ///
    /// - Parameters:
    ///   - keyPath: The path to this entity's `EntityStore` on the root state.
    ///   - policy: Narrows the coordinator's merge policy for this entity only.
    ///     Composes by ``MergePolicy/restricted(by:)``, so it can take
    ///     authority away from storage but never grant more. Use
    ///     ``MergePolicy/preferInMemory`` for a store backing a live editor.
    ///   - collapse: An optional resolver that removes duplicate rows from
    ///     disk. Without one, duplicates are harmless but permanent: writes and
    ///     deletions converge across every matching row, and reads collapse to
    ///     one value per ID, but nothing is ever deleted. Supply one to
    ///     actually reclaim them — see ``EntityCollapse`` for the determinism
    ///     and idempotence requirements, which are load-bearing under CloudKit.
    ///     Runs on hydration and re-hydration, not on the write path.
    /// - Returns: The registration to pass to ``PersistenceCoordinator``.
    @MainActor
    public static func entity<E: PersistableEntity>(
        _ keyPath: WritableKeyPath<State, EntityStore<E>>,
        policy: MergePolicy? = nil,
        collapse: (@Sendable (_ rows: [E]) -> [E])? = nil
    ) -> PersistedEntity<State> where E.Model: PersistentModel {
        let unpersisted = UnpersistedIDs()

        /// Reads the rows to fold in, running the registered collapse first
        /// when there is one. Collapse already returns the survivors, so this
        /// never fetches the same table twice.
        @MainActor
        func loadRows(_ handle: DatabaseHandle) async throws -> (rows: [E], removedIDs: Set<UUID>) {
            guard let collapse else {
                return (try await handle.db.fetchAll(E.Model.self), [])
            }
            let outcome = try await handle.db.collapseDuplicates(as: E.Model.self, using: collapse)
            return (outcome.survivors, outcome.removedIDs)
        }

        return PersistedEntity(
            makeWriter: { handle, onFailure in
                StateWriter(keyPath: keyPath) { writes, deletions in
                    let touched = Set(writes.map(\.id)).union(deletions)
                    do {
                        // One transaction per batch: a crash can't persist a
                        // partial flush, and a failure is reported, not eaten.
                        try await handle.db.apply(writes: writes, deletions: deletions, as: E.Model.self)
                        await unpersisted.markPersisted(touched)
                    } catch {
                        // The buffer is already cleared, so without this the
                        // fact that memory ≠ storage would be recorded nowhere.
                        await unpersisted.markFailed(touched)
                        onFailure(
                            PersistenceFailure(operation: .save, entityType: "\(E.self)", underlying: error))
                    }
                }
            },
            policy: policy,
            unpersisted: unpersisted,
            readForHydrate: { handle, onFailure in
                do {
                    // Removals are implicit here: the whole store is replaced
                    // by the survivors.
                    let loaded = try await loadRows(handle)
                    return { state in state[keyPath: keyPath] = EntityStore(loaded.rows) }
                } catch {
                    // Leave the store untouched — an unreadable database must
                    // not present as "no data" (a later flush would then write
                    // an empty world view over whatever is recoverable).
                    onFailure(
                        PersistenceFailure(operation: .fetch, entityType: "\(E.self)", underlying: error))
                    return { _ in }
                }
            },
            readForMerge: { handle, onFailure in
                do {
                    let loaded = try await loadRows(handle)
                    let incoming = EntityStore(loaded.rows)
                    return { state, context in
                        var current = state[keyPath: keyPath]
                        // A collapsed-away loser would otherwise linger as a
                        // zombie until relaunch. Recorded as a deletion so it
                        // also propagates to any peer that still holds it.
                        current.remove(ids: loaded.removedIDs)
                        // "In-memory wins" is just "preserve everything already
                        // held", so one primitive serves every policy.
                        let preserved =
                            context.policy.remoteWinsOnConflict
                            ? context.locallyOwnedIDs
                            : context.locallyOwnedIDs.union(current.values.map(\.id))
                        // An empty snapshot is indistinguishable from a store
                        // that is unreadable or mid-import, so refuse to read
                        // "everything was deleted" out of it — the same stance
                        // hydration takes on a failed fetch.
                        let removes =
                            context.policy.removesMissingEntities
                            && !(incoming.isEmpty && !current.isEmpty)
                        current.reconcile(
                            with: incoming, preserving: preserved, removingMissing: removes)
                        state[keyPath: keyPath] = current
                    }
                } catch {
                    onFailure(
                        PersistenceFailure(operation: .fetch, entityType: "\(E.self)", underlying: error))
                    return { _, _ in }
                }
            },
            collapseOnDisk: { handle, onFailure in
                guard collapse != nil else { return { _ in } }
                do {
                    let loaded = try await loadRows(handle)
                    guard !loaded.removedIDs.isEmpty else { return { _ in } }
                    return { state in state[keyPath: keyPath].remove(ids: loaded.removedIDs) }
                } catch {
                    onFailure(
                        PersistenceFailure(operation: .save, entityType: "\(E.self)", underlying: error))
                    return { _ in }
                }
            }
        )
    }
}
