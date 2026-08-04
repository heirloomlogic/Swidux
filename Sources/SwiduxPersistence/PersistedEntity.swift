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
/// Build with ``entity(_:)`` and pass the array to the coordinator. The only
/// re-hydration path exposed is a non-destructive `merge`, so a "refresh from
/// disk" can never clobber unflushed writes or live UI edits (rule #8).
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

    let model: any PersistentModel.Type
    let makeWriter: @MainActor (DatabaseHandle, @escaping PersistenceFailureHandler) -> StateWriter<State>

    /// Phase 1 of first-load hydration: reads the database, touches no state.
    let readForHydrate: @MainActor (DatabaseHandle, PersistenceFailureHandler) async -> Apply

    /// Phase 1 of re-hydration: reads the database, touches no state.
    let readForMerge: @MainActor (DatabaseHandle, PersistenceFailureHandler) async -> Apply

    /// Runs the registered collapse against disk, if any, and returns the fold
    /// that removes the losers from live state.
    let collapseOnDisk: @MainActor (DatabaseHandle, PersistenceFailureHandler) async -> Apply

    /// Registers the `EntityStore<E>` at `keyPath` for persistence.
    ///
    /// - Parameters:
    ///   - keyPath: The path to this entity's `EntityStore` on the root state.
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
        collapse: (@Sendable (_ rows: [E]) -> [E])? = nil
    ) -> PersistedEntity<State> where E.Model: PersistentModel {
        PersistedEntity(
            model: E.Model.self,
            makeWriter: { handle, onFailure in
                StateWriter(keyPath: keyPath) { writes, deletions in
                    do {
                        // One transaction per batch: a crash can't persist a
                        // partial flush, and a failure is reported, not eaten.
                        try await handle.db.apply(writes: writes, deletions: deletions, as: E.Model.self)
                    } catch {
                        onFailure(
                            PersistenceFailure(operation: .save, entityType: "\(E.self)", underlying: error))
                    }
                }
            },
            readForHydrate: { handle, onFailure in
                do {
                    let fetched = try await handle.db.fetchAll(E.Model.self)
                    return { state in state[keyPath: keyPath] = EntityStore(fetched) }
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
                    let incoming = EntityStore(try await handle.db.fetchAll(E.Model.self))
                    return { state in
                        var merged = state[keyPath: keyPath]
                        // Prefer existing in-memory values; absorb disk-only rows.
                        merged.merge(from: incoming) { _, _ in false }
                        state[keyPath: keyPath] = merged
                    }
                } catch {
                    onFailure(
                        PersistenceFailure(operation: .fetch, entityType: "\(E.self)", underlying: error))
                    return { _ in }
                }
            },
            collapseOnDisk: { handle, onFailure in
                guard let collapse else { return { _ in } }
                do {
                    let outcome = try await handle.db.collapseDuplicates(as: E.Model.self, using: collapse)
                    guard !outcome.removedIDs.isEmpty else { return { _ in } }
                    return { state in
                        // Record the removals. A collapsed-away loser would
                        // otherwise linger in memory as a zombie until relaunch,
                        // and the merge that follows would happily keep it. The
                        // recorded deletions flush later as no-ops against rows
                        // that are already gone, which is harmless.
                        state[keyPath: keyPath].remove(ids: outcome.removedIDs)
                    }
                } catch {
                    onFailure(
                        PersistenceFailure(operation: .save, entityType: "\(E.self)", underlying: error))
                    return { _ in }
                }
            }
        )
    }
}
