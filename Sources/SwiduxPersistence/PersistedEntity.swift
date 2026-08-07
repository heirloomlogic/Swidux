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

    let makeWriter: @MainActor (DatabaseHandle, PersistenceObservers) -> StateWriter<State>

    /// A per-entity narrowing of the coordinator's merge policy, if any.
    let policy: MergePolicy?

    /// IDs whose last save failed — memory and storage disagree, and nothing
    /// else records it.
    let unpersisted: UnpersistedIDs

    /// Phase 1 of first-load hydration: reads the database, touches no state.
    let readForHydrate: @MainActor (DatabaseHandle, PersistenceObservers) async -> Apply

    /// Phase 1 of re-hydration: reads the database, touches no state.
    let readForMerge: @MainActor (DatabaseHandle, PersistenceObservers) async -> MergeApply

    /// Runs the registered collapse against disk, if any, and returns the fold
    /// that removes the losers from live state.
    let collapseOnDisk: @MainActor (DatabaseHandle, PersistenceObservers) async -> Apply

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
        let entityTypeName = "\(E.self)"

        /// Reads the rows to fold in, running the registered collapse first
        /// when there is one. Collapse already returns the survivors, so this
        /// never fetches the same table twice.
        ///
        /// Reports any duplicates it collapsed on the way past. A registered
        /// resolver does not make them go away — rows sharing a *surviving* ID
        /// are converged, not deleted — so both branches have something to say.
        @MainActor
        func loadRows(
            _ handle: DatabaseHandle,
            _ observers: PersistenceObservers
        ) async throws -> (rows: [E], removedIDs: Set<UUID>) {
            let rows: [E]
            let removedIDs: Set<UUID>
            let duplicates: Int
            if let collapse {
                let outcome = try await handle.db.collapseDuplicates(
                    as: E.Model.self, using: collapse)
                (rows, removedIDs, duplicates) = (
                    outcome.survivors, outcome.removedIDs, outcome.duplicateRowCount
                )
            } else {
                let fetched = try await handle.db.fetchAllCollapsing(E.Model.self)
                (rows, removedIDs, duplicates) = (fetched.domains, [], fetched.duplicatesCollapsed)
            }
            if duplicates > 0 {
                observers.onDiagnostic(
                    .duplicateRowsCollapsed(entityType: entityTypeName, count: duplicates))
            }
            return (rows, removedIDs)
        }

        return PersistedEntity(
            makeWriter: { handle, observers in
                StateWriter(
                    keyPath: keyPath,
                    onExhausted: { error in
                        // The retries are spent. Say so plainly: everything
                        // before this was "we'll try again", and an app that
                        // wants to warn the user has been waiting for the
                        // difference.
                        observers.onFailure(
                            PersistenceFailure(
                                operation: .save, entityType: entityTypeName, underlying: error,
                                isFinal: true))
                    }
                ) { writes, deletions in
                    let touched = Set(writes.map(\.id)).union(deletions)
                    /// Applies a ledger change and reports the result, but only
                    /// when it actually moved: a repeated failure on the same
                    /// IDs is not news, and the empty set on recovery is.
                    ///
                    /// Takes the mutation rather than its result so the change
                    /// and the read of `ids` share one hop — otherwise the set
                    /// reported is not necessarily the one the change produced.
                    @MainActor
                    func record(_ change: @MainActor (UnpersistedIDs) -> Bool) {
                        guard change(unpersisted) else { return }
                        observers.onDiagnostic(
                            .writesUnpersisted(entityType: entityTypeName, ids: unpersisted.ids))
                    }
                    do {
                        // One transaction per batch: a crash can't persist a
                        // partial flush, and a failure is reported, not eaten.
                        try await handle.db.apply(writes: writes, deletions: deletions, as: E.Model.self)
                        await record { $0.markPersisted(touched) }
                    } catch {
                        // Belt and braces alongside the writer putting the batch
                        // back: this records memory ≠ storage even for the
                        // window where the batch is mid-flight, and it is the
                        // only record a hand-written non-throwing persist
                        // closure could leave.
                        await record { $0.markFailed(touched) }
                        observers.onFailure(
                            PersistenceFailure(operation: .save, entityType: entityTypeName, underlying: error))
                        // Rethrow so the writer puts the batch back and the
                        // plugin retries it. Swallowing here is what made a
                        // failed save silent data loss.
                        throw error
                    }
                }
            },
            policy: policy,
            unpersisted: unpersisted,
            readForHydrate: { handle, observers in
                do {
                    // Removals are implicit here: the whole store is replaced
                    // by the survivors.
                    let loaded = try await loadRows(handle, observers)
                    return { state in state[keyPath: keyPath] = EntityStore(loaded.rows) }
                } catch {
                    // Leave the store untouched — an unreadable database must
                    // not present as "no data" (a later flush would then write
                    // an empty world view over whatever is recoverable).
                    observers.onFailure(
                        PersistenceFailure(operation: .fetch, entityType: entityTypeName, underlying: error))
                    return { _ in }
                }
            },
            readForMerge: { handle, observers in
                do {
                    let loaded = try await loadRows(handle, observers)
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
                    observers.onFailure(
                        PersistenceFailure(operation: .fetch, entityType: entityTypeName, underlying: error))
                    return { _, _ in }
                }
            },
            collapseOnDisk: { handle, observers in
                guard collapse != nil else { return { _ in } }
                do {
                    let loaded = try await loadRows(handle, observers)
                    guard !loaded.removedIDs.isEmpty else { return { _ in } }
                    return { state in state[keyPath: keyPath].remove(ids: loaded.removedIDs) }
                } catch {
                    observers.onFailure(
                        PersistenceFailure(operation: .save, entityType: entityTypeName, underlying: error))
                    return { _ in }
                }
            }
        )
    }
}
