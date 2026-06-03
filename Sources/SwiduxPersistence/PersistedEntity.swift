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
    let makeWriter: @MainActor (DatabaseHandle) -> StateWriter<State>
    let hydrate: @MainActor (DatabaseHandle, inout State) async -> Void
    let mergeRemote: @MainActor (DatabaseHandle, inout State) async -> Void

    /// Registers the `EntityStore<E>` at `keyPath` for persistence.
    @MainActor
    public static func entity<E: PersistableEntity>(
        _ keyPath: WritableKeyPath<State, EntityStore<E>>
    ) -> PersistedEntity<State> where E.Model: PersistentModel {
        PersistedEntity(
            model: E.Model.self,
            makeWriter: { handle in
                StateWriter(keyPath: keyPath) { writes, deletions in
                    for entity in writes {
                        try? await handle.db.upsert(entity, as: E.Model.self)
                    }
                    for id in deletions {
                        try? await handle.db.delete(id: id, as: E.Model.self)
                    }
                }
            },
            hydrate: { handle, state in
                let fetched = (try? await handle.db.fetchAll(E.Model.self)) ?? []
                state[keyPath: keyPath] = EntityStore(fetched)
            },
            mergeRemote: { handle, state in
                let fetched = (try? await handle.db.fetchAll(E.Model.self)) ?? []
                var merged = state[keyPath: keyPath]
                // Prefer existing in-memory values; absorb disk-only rows.
                merged.merge(from: EntityStore(fetched)) { _, _ in false }
                state[keyPath: keyPath] = merged
            }
        )
    }
}
