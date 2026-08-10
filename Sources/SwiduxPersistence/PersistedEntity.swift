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
    ///
    /// Returns what it declined to act on, which is not the same as what it left
    /// alone: these are rows storage had something to say about and the merge
    /// chose not to hear. A whole-table caller can ignore that, because the next
    /// tick re-reads everything and offers the change again. A caller driving off
    /// a history watermark cannot — for it, evidence is consumed once, so a
    /// deferral it doesn't carry forward becomes a permanent loss.
    typealias MergeApply = @MainActor (inout State, MergeContext) -> Withheld

    /// A fetched merge, plus whether the fetch actually happened.
    ///
    /// `succeeded == false` means the read threw and `apply` is a no-op. A
    /// whole-table re-hydration is indifferent to the difference; a
    /// watermark-driven caller must never advance past a window it did not read.
    struct MergeRead {
        /// Whether every fetch behind `apply` completed.
        let succeeded: Bool

        /// The fold to apply. A no-op when `succeeded` is `false`.
        let apply: MergeApply
    }

    let makeWriter: @MainActor (DatabaseHandle, PersistenceObservers) -> StateWriter<State>

    /// A per-entity narrowing of the coordinator's merge policy, if any.
    let policy: MergePolicy?

    /// IDs whose last save failed — memory and storage disagree, and nothing
    /// else records it.
    let unpersisted: UnpersistedIDs

    /// Phase 1 of first-load hydration: reads the database, touches no state.
    let readForHydrate: @MainActor (DatabaseHandle, PersistenceObservers) async -> Apply

    /// Phase 1 of re-hydration: reads the database, touches no state.
    let readForMerge: @MainActor (DatabaseHandle, PersistenceObservers) async -> MergeRead

    /// Phase 1 of a *partial* re-hydration: reads only the named rows, touches
    /// no state. The IDs are everything the caller wants looked at — the ones it
    /// believes changed plus the ones it believes were deleted, since a row
    /// still on disk is what refutes a stale tombstone.
    let readForPartialMerge: @MainActor (DatabaseHandle, PersistenceObservers, Set<UUID>) async -> MergeRead

    /// Runs the registered collapse against disk, if any, and returns the fold
    /// that removes the losers from live state.
    let collapseOnDisk: @MainActor (DatabaseHandle, PersistenceObservers) async -> Apply

    /// `Schema.entityName(for:)` for this registration's model — how a merge
    /// tells which of the identities it was handed are this entity's.
    ///
    /// The *model's* name, not the domain type's: it is what a
    /// `PersistentIdentifier` reports, and so what a history scan attributes a
    /// change with. Read off the history reader rather than stored again, so the
    /// name a scan groups by and the name a merge matches on cannot drift apart.
    /// Two registrations over the same model share it, and should — whatever
    /// names one of them names both.
    var entityName: String { historyReader.entityName }

    /// This entity's contribution to a persistent-history scan.
    ///
    /// Built here rather than in the scan because reading a tombstone needs
    /// `E.Model` bound concretely, and this factory is the only place it is.
    let historyReader: EntityHistoryReader

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
            reportDuplicates(duplicates, to: observers)
            return (rows, removedIDs)
        }

        /// Emits the duplicate-collapse diagnostic, when there was one.
        ///
        /// Both read paths collapse and both have to say so; only the count
        /// differs. Kept in one place so a change to what the diagnostic carries
        /// can't reach one path and miss the other.
        @MainActor
        func reportDuplicates(_ count: Int, to observers: PersistenceObservers) {
            guard count > 0 else { return }
            observers.onDiagnostic(
                .duplicateRowsCollapsed(entityType: entityTypeName, count: count))
        }

        /// The bookkeeping both merges share: which IDs storage has no authority
        /// over, and which editing holds actually cost something.
        ///
        /// `absenceRemoves` answers "would this ID have been removed, had the
        /// hold not been in force?" for a row storage no longer has — inferred
        /// from absence on the full path, declared outright on the partial one.
        /// It is the only thing the two paths disagree about here.
        ///
        /// `candidates` is every ID this merge could possibly act on. It exists
        /// so "in-memory wins" costs what the merge costs: `reconcile` consults
        /// the preserved set only for rows it is about to write or remove, so
        /// naming the whole table would make an O(k) merge allocate O(N) —
        /// precisely what the by-ID path is for. The full path passes every held
        /// ID because it really can act on any of them.
        ///
        /// - Returns: The IDs to preserve through the reconcile, and the ones an
        ///   editing hold actually cost this merge.
        @MainActor
        func resolvePreserved(
            current: EntityStore<E>,
            incoming: EntityStore<E>,
            candidates: some Sequence<UUID>,
            context: MergeContext,
            observers: PersistenceObservers,
            absenceRemoves: (UUID) -> Bool
        ) -> (preserved: Set<UUID>, withheld: Withheld) {
            // "In-memory wins" is just "preserve everything already held", so
            // one primitive serves every policy. Candidates the store doesn't
            // hold are dropped: preserving one would block the insert that
            // additive merging is supposed to make.
            let preserved =
                context.policy.remoteWinsOnConflict
                ? context.locallyOwnedIDs
                : context.locallyOwnedIDs.union(candidates.lazy.filter(current.contains))
            // Report only holds that actually cost something. The hold is in
            // force on every tick an open editor produces, so reporting one per
            // tick would drown the channel and say nothing about a leak.
            //
            // That same filter is what makes this the right thing to return. It
            // is exactly "storage had something to say about this row and the
            // merge declined to hear it" — and an editing hold is the one
            // exemption that leaves *no other trace*. A pending or failed write
            // will reach disk and overwrite the remote value, so nothing is owed
            // once it lands; a hold protects a value that was never dispatched at
            // all, so when it lifts, disk still holds the change and only another
            // merge can deliver it.
            //
            // Which way it was withheld is recorded, not just that it was: a
            // deferred deletion has no row left to re-read, so re-offering it
            // means declaring it again.
            var withheld = Withheld()
            for id in context.heldIDs {
                guard let held = current[id] else { continue }
                guard let stored = incoming[id] else {
                    if absenceRemoves(id) { withheld.deleted.insert(id) }
                    continue
                }
                if stored != held { withheld.changed.insert(id) }
            }
            if !withheld.isEmpty {
                observers.onDiagnostic(.mergeWithheld(entityType: entityTypeName, ids: withheld.ids))
            }
            return (preserved, withheld)
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
                    return MergeRead(succeeded: true) { state, context in
                        var current = state[keyPath: keyPath]
                        // A collapsed-away loser would otherwise linger as a
                        // zombie until relaunch. Recorded as a deletion so it
                        // also propagates to any peer that still holds it.
                        current.remove(ids: loaded.removedIDs)
                        // An empty snapshot is indistinguishable from a store
                        // that is unreadable or mid-import, so refuse to read
                        // "everything was deleted" out of it — the same stance
                        // hydration takes on a failed fetch.
                        let removes =
                            context.policy.removesMissingEntities
                            && !(incoming.isEmpty && !current.isEmpty)
                        // Every held ID is a candidate: a full merge can write or
                        // remove any row in the table.
                        let resolved = resolvePreserved(
                            current: current, incoming: incoming,
                            candidates: current.values.lazy.map(\.id), context: context,
                            observers: observers, absenceRemoves: { _ in removes })
                        current.reconcile(
                            with: incoming, preserving: resolved.preserved, removingMissing: removes)
                        state[keyPath: keyPath] = current
                        return resolved.withheld
                    }
                } catch {
                    observers.onFailure(
                        PersistenceFailure(operation: .fetch, entityType: entityTypeName, underlying: error))
                    return MergeRead(succeeded: false) { _, _ in Withheld() }
                }
            },
            readForPartialMerge: { handle, observers, ids in
                do {
                    // The registered collapse resolver deliberately does not run
                    // here: it is handed every row of the table and asked which
                    // survive, so running it against a subset would have it
                    // judge a world it cannot see. Duplicates are still
                    // collapsed on read, and still reported.
                    let fetched = try await handle.db.fetchCollapsing(ids: ids, as: E.Model.self)
                    reportDuplicates(fetched.duplicatesCollapsed, to: observers)
                    let incoming = EntityStore(fetched.domains)
                    return MergeRead(succeeded: true) { state, context in
                        var current = state[keyPath: keyPath]
                        // No empty-snapshot guard, and none needed: this path
                        // never infers a deletion, so an empty read removes
                        // nothing on its own. Removal is exactly what the caller
                        // declared, where policy grants the authority.
                        let deleting =
                            context.policy.removesMissingEntities ? context.deletedIDs : []
                        // Only the rows this merge can reach: `reconcile` writes
                        // what the snapshot holds and removes what was declared,
                        // and consults the preserved set for nothing else.
                        let resolved = resolvePreserved(
                            current: current, incoming: incoming,
                            candidates: incoming.values.map(\.id) + deleting, context: context,
                            observers: observers, absenceRemoves: { deleting.contains($0) })
                        current.reconcile(
                            with: incoming, deleting: deleting, preserving: resolved.preserved)
                        state[keyPath: keyPath] = current
                        return resolved.withheld
                    }
                } catch {
                    observers.onFailure(
                        PersistenceFailure(operation: .fetch, entityType: entityTypeName, underlying: error))
                    return MergeRead(succeeded: false) { _, _ in Withheld() }
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
            },
            historyReader: EntityHistoryReader(
                entityName: Schema.entityName(for: E.Model.self),
                modelType: E.Model.self,
                tombstoneID: { change in
                    guard case .delete(let deletion) = change else { return nil }
                    // Pattern-match *then* bind: `HistoryChange` is an enum, and
                    // casting one straight to `any HistoryDelete` compiles and
                    // always misses.
                    guard let tombstone = (deletion as? any HistoryDelete<E.Model>)?.tombstone else {
                        return nil
                    }
                    // Iterated, not `tombstone[\.id]`. The subscript looks a value
                    // up by key-path identity, and `\E.Model.id` written here —
                    // in a generic context — is the protocol witness rather than
                    // the stored attribute the tombstone is keyed by, so it
                    // silently finds nothing. In Debug as well as Release.
                    //
                    // Requiring *exactly* one identity is the safety: `@Persisted`
                    // preserves only `id`, so a tombstone carrying several
                    // candidates came from a model this can't read, and guessing
                    // between them would delete the wrong row. Nil escalates the
                    // tick to a full re-hydration, which needs no tombstone.
                    let candidates = tombstone.compactMap { $0 as? UUID }
                    return candidates.count == 1 ? candidates.first : nil
                }
            )
        )
    }
}
