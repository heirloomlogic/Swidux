//
//  StateWriter.swift
//  Swidux
//
//  Drains an EntityStore's changelog and accumulates pending writes.
//  Each StateWriter manages one entity type. Later writes for the same ID
//  overwrite earlier ones, naturally coalescing rapid mutations.
//

import Foundation

/// Accumulates entity snapshots and produces batched async persistence work.
///
/// ## Lifecycle
///
/// 1. **Drain** — called synchronously after each reducer. Moves changed IDs
///    from the `EntityStore` into the state writer's own pending buffers.
///    Later values for the same ID overwrite earlier ones.
/// 2. **Flush** — called when the debounce timer fires. Returns an async
///    closure that persists the accumulated batch, then clears the buffers.
/// 3. **Restore** — if that save throws, the batch goes back into the pending
///    buffers rather than being lost, and the closure reports
///    ``FlushOutcome/failed`` so ``PersistencePlugin`` can retry it. Restoring
///    never overwrites newer intent: a write drained while the save was in
///    flight supersedes the restored value, and a write and a deletion for one
///    ID never travel together.
@MainActor
public final class StateWriter<State> {
    private let drainBody: (inout State) -> Bool
    private let flushBody: () -> (@MainActor () async -> FlushOutcome)?
    private let pendingIDsBody: () -> Set<UUID>
    private let exhaustedBody: () -> Void
    private let recordFlushesBody: () -> FlushRecord

    /// Creates a state writer for one `EntityStore` key path.
    ///
    /// - Parameters:
    ///   - keyPath: The path to the `EntityStore` on the root state.
    ///   - onExhausted: Called with the last error when ``PersistencePlugin``
    ///     stops retrying this writer's batch. The batch is *not* discarded —
    ///     it stays pending, so a later edit or an explicit flush tries again —
    ///     but until one of those happens the value exists only in memory.
    ///   - persist: An async closure that receives the batched writes and deletions.
    ///             Called off the MainActor when the debounce timer fires. If it
    ///             throws, the batch is put back into the pending buffers rather
    ///             than lost, and the plugin retries it.
    public init<Entity: Identifiable & Equatable & Sendable>(
        keyPath: WritableKeyPath<State, EntityStore<Entity>>,
        onExhausted: (@MainActor (any Error) -> Void)? = nil,
        persist: @escaping @Sendable (_ writes: [Entity], _ deletions: Set<UUID>) async throws -> Void
    ) where Entity.ID == UUID {
        var pendingWrites: [UUID: Entity] = [:]
        var pendingDeletions: Set<UUID> = []
        var lastError: (any Error)?
        // Held weakly: a record is open for as long as its reader keeps it, so
        // nobody has to remember to close one, and a writer nobody is watching
        // logs nothing.
        var records: [WeakFlushRecord] = []

        drainBody = { state in
            let changes = state[keyPath: keyPath].changes
            guard !changes.isEmpty else { return false }

            for id in changes.upserts {
                if let entity = state[keyPath: keyPath][id] {
                    pendingWrites[id] = entity
                    // A reinsert in this drain cancels a deletion buffered by an
                    // earlier drain — otherwise the flush batch would carry both
                    // and the delete would win at the database.
                    pendingDeletions.remove(id)
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
            // Recorded in the same synchronous step that empties the buffers,
            // so there is no instant at which these IDs are in neither place.
            records.removeAll { $0.record == nil }
            if !records.isEmpty {
                let flushed = Set(pendingWrites.keys).union(deletions)
                for entry in records { entry.record?.formUnion(flushed) }
            }
            pendingWrites.removeAll(keepingCapacity: true)
            pendingDeletions.removeAll(keepingCapacity: true)
            return {
                do {
                    try await persist(writes, deletions)
                    return .persisted
                } catch {
                    lastError = error
                    // Put the batch back so it is retried rather than lost —
                    // but never over anything newer. A drain that landed while
                    // the save was suspended is the more recent intent, and the
                    // precedence rules are the ones `drain` already applies:
                    // a later write supersedes, and a write and a deletion for
                    // one ID must never travel together or the delete wins at
                    // the database.
                    for entity in writes
                    where pendingWrites[entity.id] == nil && !pendingDeletions.contains(entity.id) {
                        pendingWrites[entity.id] = entity
                    }
                    for id in deletions where pendingWrites[id] == nil {
                        pendingDeletions.insert(id)
                    }
                    return .failed
                }
            }
        }

        pendingIDsBody = { Set(pendingWrites.keys).union(pendingDeletions) }

        recordFlushesBody = {
            let record = FlushRecord()
            records.removeAll { $0.record == nil }
            records.append(WeakFlushRecord(record: record))
            return record
        }

        exhaustedBody = {
            guard let error = lastError else { return }
            onExhausted?(error)
        }
    }

    /// IDs with a drained-but-unflushed local write or deletion.
    ///
    /// Read synchronously by the remote merge to decide which IDs a storage
    /// snapshot has no authority over. Empty immediately after a successful
    /// ``flush()``, and repopulated by any ``drain(_:)`` that follows —
    /// including one that runs while a flush is suspended, which is precisely
    /// the window the merge needs to know about.
    ///
    /// This is *not* the whole picture on its own: mutations that have not been
    /// drained yet live in the `EntityStore`'s own `changes`, a write whose
    /// save failed is in neither place, and a batch a flush has already handed
    /// to `persist` is no longer here at all — see ``recordFlushes()``.
    public var pendingIDs: Set<UUID> { pendingIDsBody() }

    /// Starts recording every ID this writer hands to its `persist` closure,
    /// from now until the returned record is released.
    ///
    /// ``pendingIDs`` empties the moment a flush takes a batch, so a reader
    /// that suspends — a merge fetching rows from storage — cannot tell from it
    /// alone that a debounce flush saved a newer value while it was away. Its
    /// read predates that save, and applying it would roll memory back to a
    /// value storage no longer holds. Open a record before the read and treat
    /// its ``FlushRecord/ids`` as locally owned alongside ``pendingIDs``.
    ///
    /// Nothing needs closing: the writer holds records weakly and stops
    /// appending to one once its owner lets it go, and logs nothing at all
    /// while no record is open.
    ///
    /// - Returns: A record that grows by each later batch's IDs.
    public func recordFlushes() -> FlushRecord { recordFlushesBody() }

    /// Drains the `EntityStore` `ChangeSet` into pending buffers.
    ///
    /// Returns `true` if there were changes to drain.
    public func drain(_ state: inout State) -> Bool { drainBody(&state) }

    /// Returns an async closure with the batched persistence work.
    ///
    /// Returns `nil` if nothing is pending. Clears the buffers — but a batch
    /// whose save throws is put back, so the work reports
    /// ``FlushOutcome/failed`` and the same writes are pending again when it
    /// returns.
    public func flush() -> (@MainActor () async -> FlushOutcome)? { flushBody() }

    /// Reports that ``PersistencePlugin`` has stopped retrying this writer.
    ///
    /// Fires the `onExhausted` hook with the error from the last attempt. The
    /// pending batch is deliberately left alone: dropping it would restore the
    /// data loss retrying exists to prevent, and keeping it means the next
    /// drain or explicit flush tries once more.
    public func retryBudgetExhausted() { exhaustedBody() }
}

/// The IDs a ``StateWriter`` has handed to its `persist` closure since the
/// record was opened with ``StateWriter/recordFlushes()``.
///
/// Every one of them has left the writer's pending buffers, so none of them is
/// in ``StateWriter/pendingIDs``. Each is on its way to storage — or already
/// there — with a value newer than anything read from storage before the
/// record was opened. A batch whose save fails is also put back into the
/// pending buffers, so it appears in both.
@MainActor
public final class FlushRecord {
    /// Every ID flushed since the record was opened, writes and deletions alike.
    public private(set) var ids: Set<UUID> = []

    fileprivate init() {}

    fileprivate func formUnion(_ flushed: Set<UUID>) {
        ids.formUnion(flushed)
    }
}

/// A ``FlushRecord`` a writer appends to only while someone else keeps it.
@MainActor
private struct WeakFlushRecord {
    weak var record: FlushRecord?
}
