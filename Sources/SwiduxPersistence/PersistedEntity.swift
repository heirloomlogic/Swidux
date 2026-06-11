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
public struct PersistedEntity<State> {
    let model: any PersistentModel.Type
    let makeWriter: @MainActor (DatabaseHandle, @escaping PersistenceFailureHandler) -> StateWriter<State>
    let hydrate: @MainActor (DatabaseHandle, inout State, PersistenceFailureHandler) async -> Void
    let mergeRemote: @MainActor (DatabaseHandle, inout State, PersistenceFailureHandler) async -> Void

    /// Registers the `EntityStore<E>` at `keyPath` for persistence.
    @MainActor
    public static func entity<E: PersistableEntity>(
        _ keyPath: WritableKeyPath<State, EntityStore<E>>
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
            hydrate: { handle, state, onFailure in
                do {
                    let fetched = try await handle.db.fetchAll(E.Model.self)
                    state[keyPath: keyPath] = EntityStore(fetched)
                } catch {
                    // Leave the store untouched — an unreadable database must
                    // not present as "no data" (a later flush would then write
                    // an empty world view over whatever is recoverable).
                    onFailure(
                        PersistenceFailure(operation: .fetch, entityType: "\(E.self)", underlying: error))
                }
            },
            mergeRemote: { handle, state, onFailure in
                do {
                    let fetched = try await handle.db.fetchAll(E.Model.self)
                    var merged = state[keyPath: keyPath]
                    // Prefer existing in-memory values; absorb disk-only rows.
                    merged.merge(from: EntityStore(fetched)) { _, _ in false }
                    state[keyPath: keyPath] = merged
                } catch {
                    onFailure(
                        PersistenceFailure(operation: .fetch, entityType: "\(E.self)", underlying: error))
                }
            }
        )
    }
}
