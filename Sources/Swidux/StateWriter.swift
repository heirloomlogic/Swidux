//
//  StateWriter.swift
//  Swidux
//
//  Drains an EntityStore's changelog and accumulates pending writes.
//  Each StateWriter manages one entity type. Later writes for the same ID
//  overwrite earlier ones, naturally coalescing rapid mutations.
//

import Foundation

/// Accumulates entity snapshots from an `EntityStore`'s `ChangeSet` and
/// produces batched async persistence work on demand.
///
/// ## Lifecycle
///
/// 1. **Drain** — called synchronously after each reducer. Moves changed IDs
///    from the `EntityStore` into the state writer's own pending buffers.
///    Later values for the same ID overwrite earlier ones.
/// 2. **Flush** — called when the debounce timer fires. Returns an async
///    closure that persists the accumulated batch, then clears the buffers.
public final class StateWriter<State> {
    private let drainBody: (inout State) -> Bool
    private let flushBody: () -> (@Sendable () async -> Void)?

    /// Creates a state writer for one `EntityStore` key path.
    ///
    /// - Parameters:
    ///   - keyPath: The path to the `EntityStore` on the root state.
    ///   - persist: An async closure that receives the batched writes and deletions.
    ///             Called off the MainActor when the debounce timer fires.
    public init<Entity: Identifiable & Equatable & Sendable>(
        keyPath: WritableKeyPath<State, EntityStore<Entity>>,
        persist: @escaping @Sendable (_ writes: [Entity], _ deletions: Set<UUID>) async -> Void
    ) where Entity.ID == UUID {
        var pendingWrites: [UUID: Entity] = [:]
        var pendingDeletions: Set<UUID> = []

        drainBody = { state in
            let changes = state[keyPath: keyPath].changes
            guard !changes.isEmpty else { return false }

            for id in changes.upserts {
                if let entity = state[keyPath: keyPath][id] {
                    pendingWrites[id] = entity
                }
            }
            pendingDeletions.formUnion(changes.deletions)

            // Remove any pending writes for entities that were subsequently deleted
            for id in changes.deletions {
                pendingWrites.removeValue(forKey: id)
            }

            state[keyPath: keyPath].resetChanges()
            return true
        }

        flushBody = {
            guard !pendingWrites.isEmpty || !pendingDeletions.isEmpty else { return nil }
            let writes = Array(pendingWrites.values)
            let deletions = pendingDeletions
            pendingWrites.removeAll(keepingCapacity: true)
            pendingDeletions.removeAll(keepingCapacity: true)
            return { await persist(writes, deletions) }
        }
    }

    /// Drains the `EntityStore`'s `ChangeSet` into pending buffers.
    /// Returns `true` if there were changes to drain.
    public func drain(_ state: inout State) -> Bool { drainBody(&state) }

    /// Returns an async closure with the batched persistence work,
    /// or `nil` if nothing is pending. Clears the buffers.
    public func flush() -> (@Sendable () async -> Void)? { flushBody() }
}
