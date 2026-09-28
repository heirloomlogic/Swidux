//
//  EntityDB.swift
//  SwiduxPersistence
//
//  One generic SwiftData actor that replaces the per-type `{Type}DB` actors
//  apps hand-write. Drives fetch/upsert/delete for any generated shadow model.
//

import Foundation
import OSLog
import SwiftData

/// A generic `@ModelActor` that reads and writes any ``PersistableModel``.
///
/// Off the main actor; all access goes through its `ModelContext`. The
/// persistence plugin calls `upsert`/`delete` from the debounced flush and
/// `fetchAll` during hydration / re-hydration.
///
/// ## Duplicate IDs are legitimate
///
/// `@Persisted` emits no `@Attribute(.unique)` on `id` — CloudKit forbids
/// unique constraints — so a fetch by ID may return **several** rows. Two
/// devices that both create the same entity offline, or a mirrored store that
/// replays a record twice, produce exactly that.
///
/// Every method here is therefore written to be *convergent*: writes update
/// **every** row sharing an ID, deletions remove **every** row sharing an ID,
/// and ``fetchAll(_:)`` collapses duplicates to one domain value. Nothing here
/// deletes a duplicate as a side effect of a write.
///
/// > Note: That last point is deliberate. "Update one row, delete the rest"
/// > looks like self-healing but loses data under CloudKit: `persistentModelID`
/// > is local, so two devices pick *different* survivors, each tombstones the
/// > other's, and after sync **both rows are gone**. Collapsing duplicates
/// > requires app knowledge of which value wins — see
/// > ``collapseDuplicates(as:using:)``.
@ModelActor
public actor EntityDB {
    private static let logger = Logger(subsystem: "swidux", category: "persistence")

    /// An error the next read should throw instead of touching the store.
    private var injectedFetchFailure: (any Error)?

    /// The author this actor stamps on the transactions a store's flush saves
    /// through it.
    ///
    /// Unique per instance, so a history scan can tell those writes from every
    /// other writer's — CloudKit's import, another process, a second
    /// `EntityDB` on the same container. A flushed batch came from the state
    /// the store holds, so the scan has nothing to learn from it that it has to
    /// trace to a parent. See `changes(since:readers:)`.
    ///
    /// Only the flush path stamps it. A write through the public API — tooling,
    /// an App Intent, an import — did not come from state, and is left
    /// unstamped so the scan treats it as the foreign write it is.
    let transactionAuthor = "swidux.\(UUID().uuidString)"

    /// Test seam: makes the next read throw `error` rather than run, so the
    /// read-failure branch of hydration and of every merge can be exercised.
    ///
    /// Nothing else can reach those branches. A store reopened `allowsSave: false`
    /// — the trick ``PersistenceCoordinator``'s retry tests use — fails *saves*
    /// and leaves reads working, which is the point of it; an in-memory store
    /// does not fail at all; and `failNextHistoryScan` covers the scan rather
    /// than the read it precedes.
    ///
    /// Like that seam, this proves the **escalation** — that a read which threw
    /// is reported and applies nothing — rather than that a real SwiftData fetch
    /// throws instead of trapping. The branch is reachable in production (a
    /// corrupt store, a revoked file handle, a container yanked mid-tick); an
    /// injected error stands in for the throw, not for its cause.
    ///
    /// One-shot, so arming it cannot poison later reads: the tick *after* the
    /// one that failed reads for real, which is what the callers that re-offer
    /// an unconsumed window assert on.
    ///
    /// Reads only, and a method rather than a settable property. The write path
    /// fetches the rows it is about to touch through the same chunked by-ID
    /// query, so seaming that shared helper would make "the read failed" and
    /// "the save failed" one event; and `EntityDB` is an actor, so cross-actor
    /// assignment to isolated state isn't expressible.
    func failNextFetch(with error: any Error) {
        injectedFetchFailure = error
    }

    /// Throws and disarms the injected failure, if one is armed.
    private func consumeInjectedFetchFailure() throws {
        guard let injected = injectedFetchFailure else { return }
        injectedFetchFailure = nil
        throw injected
    }

    /// Loads every persisted row of `M` and reconstructs domain values.
    ///
    /// Rows sharing an `id` are collapsed to the first one in fetch order:
    /// ``EntityStore`` cannot represent duplicates, and handing it a duplicate
    /// corrupts its index. Duplicates are logged, not treated as an error —
    /// they are a legitimate state under CloudKit mirroring.
    ///
    /// Throws if any row cannot be decoded, rather than returning the rest as
    /// though they were everything.
    public func fetchAll<M: PersistableModel>(_ type: M.Type) throws -> [M.Domain] {
        try fetchAllCollapsing(M.self).checked()
    }

    /// Collapses rows to one domain value per `id`, keeping the first in fetch
    /// order, and logs it when anything was collapsed.
    ///
    /// The single definition of what "collapse" means on a read, shared by the
    /// full-table and by-ID paths. Two reads of the same row disagreeing on the
    /// survivor would make a partial merge flap between values on every tick.
    ///
    /// Decoding is per row. A row this build cannot decode — typically one a
    /// newer app version wrote — is named in the result instead of failing the
    /// read, so it costs that row and not every row of its entity. An ID whose
    /// first row in fetch order will not decode is undecodable; a later
    /// duplicate is not consulted, so both read paths agree.
    ///
    /// - Returns: The domain values, how many rows were collapsed away, and the
    ///   rows that could not be decoded. The count goes back to the caller as
    ///   well as to the log: only the main actor holds the app's diagnostic
    ///   handler.
    private func collapse<M: PersistableModel>(_ rows: [M]) -> CollapsedRead<M.Domain> {
        var seen = Set<UUID>(minimumCapacity: rows.count)
        var domains: [M.Domain] = []
        domains.reserveCapacity(rows.count)
        var undecodable = UndecodableRows()
        for row in rows where seen.insert(row.id).inserted {
            do {
                domains.append(try row.toDomain())
            } catch {
                undecodable.record(row.id, error)
            }
        }
        let duplicates = rows.count - seen.count
        if duplicates > 0 {
            Self.logger.warning(
                """
                \(String(describing: M.self), privacy: .public): \
                \(duplicates, privacy: .public) duplicate row(s) collapsed on read. \
                Register a collapse closure to remove them from disk.
                """
            )
        }
        return CollapsedRead(domains: domains, duplicatesCollapsed: duplicates, undecodable: undecodable)
    }

    /// ``fetchAll(_:)`` plus how many rows it collapsed away.
    ///
    /// The count is returned rather than pushed through a handler stored on the
    /// actor: `EntityDB` is swapped wholesale when a container is rebuilt (see
    /// ``DatabaseHandle``), and a handler living here would have to be
    /// reinstalled on every swap. Callers on the main actor already hold the
    /// app's diagnostic handler, so they emit it.
    func fetchAllCollapsing<M: PersistableModel>(
        _ type: M.Type
    ) throws -> CollapsedRead<M.Domain> {
        try consumeInjectedFetchFailure()
        return collapse(try modelContext.fetch(FetchDescriptor<M>()))
    }

    /// Loads every persisted row of the **domain** type `E`.
    ///
    /// The same read as ``fetchAll(_:)``, named by the entity you wrote rather
    /// than by its generated shadow model — `fetchAll(of: Note.self)` instead
    /// of `fetchAll(NoteModel.self)`.
    public func fetchAll<E: PersistableEntity>(of type: E.Type) throws -> [E] {
        try fetchAll(E.Model.self)
    }

    /// Loads just the rows named by `ids`, and reconstructs domain values.
    ///
    /// The by-ID counterpart to ``fetchAll(of:)``: the read a caller who already
    /// knows *which* rows changed should make, instead of scanning the table to
    /// find out. Costs one round trip per ``batchFetchChunkSize`` IDs and
    /// materializes only the rows it asked for, so a sync tick that touched
    /// three rows no longer pays for the whole table.
    ///
    /// IDs with no row are skipped rather than reported, so a short result is
    /// not evidence of anything — see
    /// ``PersistenceCoordinator/mergeRemote(into:ids:deleted:policy:)`` for what
    /// that costs a merge.
    ///
    /// Rows sharing an `id` collapse to the first in fetch order, identically to
    /// ``fetchAll(of:)``. Duplicates are logged, not treated as an error.
    ///
    /// - Parameters:
    ///   - ids: The identities to load. Duplicates and unknown IDs are harmless.
    ///   - type: The domain entity type, e.g. `Note.self`.
    /// - Returns: One domain value per matched `id`, in fetch order.
    /// - Throws: Whatever the underlying fetch throws, or the decoding error of
    ///   the first row that cannot be decoded.
    public func fetch<E: PersistableEntity>(
        ids: some Sequence<UUID>,
        of type: E.Type
    ) throws -> [E] {
        try fetchCollapsing(ids: ids, as: E.Model.self).checked()
    }

    /// ``fetch(ids:of:)`` plus how many rows it collapsed away.
    ///
    /// Split out for the same reason ``fetchAllCollapsing(_:)`` is: the count
    /// goes back to the caller on the main actor, which holds the app's
    /// diagnostic handler, rather than to a handler stored on an actor that gets
    /// swapped wholesale on a container rebuild.
    func fetchCollapsing<M: PersistableModel>(
        ids: some Sequence<UUID>,
        as type: M.Type
    ) throws -> CollapsedRead<M.Domain> {
        try consumeInjectedFetchFailure()
        return collapse(try rows(ids: ids, as: M.self))
    }

    /// Inserts or updates the row for `domain.id`, then saves.
    ///
    /// Updates **every** row sharing the ID, so duplicates converge to
    /// identical content rather than leaving stale copies behind. Inserts only
    /// when no row matches.
    ///
    /// Convenience single-row API (used by tests and one-off tooling). The
    /// plugin's flush path calls ``apply(writes:deletions:as:)`` directly with
    /// the whole batch — prefer it for multi-row changes, since a sequence of
    /// single-row saves can be interrupted part-way.
    public func upsert<M: PersistableModel>(_ domain: M.Domain, as type: M.Type) throws {
        try apply(writes: [domain], deletions: [], as: M.self)
    }

    /// Chunk size for batched ID fetches. Stays comfortably under SQLite's
    /// bound-variable limit (999 in older builds), so an arbitrarily large
    /// flush batch can never overflow a single `IN (…)` clause.
    static let batchFetchChunkSize = 500

    /// Applies a whole flush batch — upserts then deletions — in a single
    /// transaction with one `save()`, so a crash can't persist a partial batch.
    ///
    /// All touched rows are fetched up front in chunks of
    /// ``batchFetchChunkSize`` via the model's generated
    /// `swiduxBatchFetchDescriptor(ids:)` — one round trip per chunk instead
    /// of one per row.
    ///
    /// Writes update **every** row sharing an ID and deletions remove **every**
    /// row sharing an ID, so a batch applied against a store holding duplicates
    /// leaves no stale or resurrectable copies.
    ///
    /// A row whose value cannot be converted to its stored form fails on its
    /// own: every other row is saved, and ``UnencodableRows`` names the ones
    /// that were not. Conversion failures are deterministic, so failing the
    /// whole batch would fail it identically on every retry — and every later
    /// edit of this type joins that batch. Any other failure rolls the context
    /// back before rethrowing, leaving no half-applied changes behind for a
    /// later save to pick up.
    ///
    /// - Throws: ``UnencodableRows`` after saving the rest of the batch, or
    ///   whatever the fetch or save throws, with nothing saved.
    public func apply<M: PersistableModel>(
        writes: [M.Domain],
        deletions: Set<UUID>,
        as type: M.Type
    ) throws {
        try apply(writes: writes, deletions: deletions, as: M.self, fromState: false)
    }

    /// ``apply(writes:deletions:as:)`` for a batch a store's flush drained from
    /// its state, stamped with ``transactionAuthor``.
    func applyFlush<M: PersistableModel>(
        writes: [M.Domain],
        deletions: Set<UUID>,
        as type: M.Type
    ) throws {
        try apply(writes: writes, deletions: deletions, as: M.self, fromState: true)
    }

    private func apply<M: PersistableModel>(
        writes: [M.Domain],
        deletions: Set<UUID>,
        as type: M.Type,
        fromState: Bool
    ) throws {
        let gate = EntityPersistenceGate.forContainer(modelContainer)
        gate.lock.lock()
        defer { gate.lock.unlock() }
        guard !gate.requiresGroups else { throw EntityPersistenceGroupError.groupedWritesRequired }
        var unencodable: Set<UUID> = []
        var firstError: (any Error)?
        // Each pass that meets a conversion failure excludes at least one more
        // row than the last, so this ends — in two passes for any batch whose
        // failures are deterministic.
        while true {
            let remaining = unencodable.isEmpty ? writes : writes.filter { !unencodable.contains($0.id) }
            let failures = try applyOnce(
                writes: remaining, deletions: deletions, as: M.self, fromState: fromState)
            guard let first = failures.first else { break }
            firstError = firstError ?? first.error
            unencodable.formUnion(failures.lazy.map(\.id))
        }
        if let firstError {
            throw UnencodableRows(failedIDs: unencodable, underlying: firstError)
        }
    }

    /// One attempt at a batch. Saves it when every row converts; otherwise rolls
    /// back and reports the rows that did not, in batch order.
    ///
    /// Nothing from a pass that met a conversion failure is saved: a throw can
    /// come part-way through `update(from:)`, leaving that row half-written in
    /// the context, and only a rollback is sure to undo it.
    private func applyOnce<M: PersistableModel>(
        writes: [M.Domain],
        deletions: Set<UUID>,
        as type: M.Type,
        fromState: Bool
    ) throws -> [(id: UUID, error: any Error)] {
        do {
            let touchedIDs = Set(writes.map(\.id)).union(deletions)
            var existingByID = try rowsByID(touchedIDs, as: M.self)
            var unencodable: [(id: UUID, error: any Error)] = []
            for domain in writes {
                do {
                    let existing = existingByID[domain.id] ?? []
                    if existing.isEmpty {
                        let inserted = try M(from: domain)
                        modelContext.insert(inserted)
                        // Keep the map faithful to context state: a later
                        // deletion of the same ID must see the pending row,
                        // exactly as a per-ID fetch would.
                        existingByID[domain.id] = [inserted]
                    } else {
                        for row in existing { try row.update(from: domain) }
                    }
                } catch {
                    unencodable.append((domain.id, error))
                }
            }
            guard unencodable.isEmpty else {
                modelContext.rollback()
                return unencodable
            }
            for id in deletions {
                for row in existingByID[id] ?? [] {
                    modelContext.delete(row)
                }
            }
            try SwiduxAssociationGraph.reconcile(models: [M.self], in: modelContext)
            modelContext.author = fromState ? transactionAuthor : nil
            try modelContext.save()
            return []
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Deletes **every** row for `id`, then saves.
    ///
    /// Removing all matches is what makes deletion converge: leaving a
    /// duplicate behind resurrects the entity on the next hydration.
    ///
    /// Convenience single-row API — see ``apply(writes:deletions:as:)`` for
    /// the transactional batch path the plugin uses.
    public func delete<M: PersistableModel>(id: UUID, as type: M.Type) throws {
        try apply(writes: [], deletions: [id], as: M.self)
    }

    /// Collapses the stored rows of `M` using an app-supplied resolver, in a
    /// single transaction.
    ///
    /// `collapse` receives **every** row on disk in fetch order, duplicates
    /// included, and returns the survivors. IDs present in the input and absent
    /// from the output are deleted, including every row carrying them.
    /// Survivors whose value differs from the stored row are written back to
    /// every row for that ID.
    ///
    /// Rows that share a *surviving* ID are converged, not deleted — see
    /// ``EntityCollapse`` for why removing an ID is safe under CloudKit and
    /// removing one of several rows sharing an ID is not.
    ///
    /// This is the only operation that deletes anything the caller did not
    /// explicitly name, and it is opt-in for a reason: the framework cannot
    /// pick a survivor safely on its own.
    ///
    /// - Returns: The survivors and the IDs removed from disk.
    /// - Throws: Whatever the underlying fetch or save throws, or the decoding
    ///   error of the first row that cannot be decoded — in which case nothing
    ///   is collapsed. The context is rolled back before rethrowing.
    @discardableResult
    public func collapseDuplicates<M: PersistableModel>(
        as type: M.Type,
        using collapse: @Sendable ([M.Domain]) -> [M.Domain]
    ) throws -> CollapseOutcome<M.Domain> {
        let collapsed = try collapsingDuplicates(as: M.self, using: collapse)
        try collapsed.undecodable.check()
        return collapsed.outcome
    }

    /// ``collapseDuplicates(as:using:)`` that reports undecodable rows instead
    /// of throwing on them.
    ///
    /// When any row cannot be decoded the resolver does not run and nothing is
    /// written: it is handed the whole table and asked which rows survive, and a
    /// table with rows missing from it is a world it cannot see. The decodable
    /// rows come back collapsed exactly as a plain read would collapse them, and
    /// the undecodable ones are reported — every one, including a duplicate a
    /// plain read would have skipped past, because it is what kept the resolver
    /// from running.
    func collapsingDuplicates<M: PersistableModel>(
        as type: M.Type,
        using collapse: @Sendable ([M.Domain]) -> [M.Domain]
    ) throws -> (outcome: CollapseOutcome<M.Domain>, undecodable: UndecodableRows) {
        let gate = EntityPersistenceGate.forContainer(modelContainer)
        gate.lock.lock()
        defer { gate.lock.unlock() }
        guard !gate.requiresGroups else { throw EntityPersistenceGroupError.groupedWritesRequired }
        do {
            let rows = try modelContext.fetch(FetchDescriptor<M>())
            // Convert once and keep the domain value beside its row: the
            // write-back below needs it again to skip no-op updates.
            var byID: [UUID: [(row: M, domain: M.Domain)]] = [:]
            var domains: [M.Domain] = []
            domains.reserveCapacity(rows.count)
            var undecodable = UndecodableRows()
            for row in rows {
                do {
                    let domain = try row.toDomain()
                    domains.append(domain)
                    byID[row.id, default: []].append((row, domain))
                } catch {
                    undecodable.record(row.id, error)
                }
            }
            guard undecodable.ids.isEmpty else {
                let read = self.collapse(rows)
                let outcome = CollapseOutcome(
                    survivors: read.domains, removedIDs: [], duplicateRowCount: read.duplicatesCollapsed)
                return (outcome, undecodable)
            }

            let survivors = collapse(domains)
            let survivingIDs = Set(survivors.map(\.id))

            // Only worth re-running the resolver when it actually changed
            // something — otherwise every hydration pays for it in debug.
            assert(
                survivors.count == rows.count || Set(collapse(survivors).map(\.id)) == survivingIDs,
                """
                collapse must be idempotent: re-running it on its own output changed the surviving IDs. \
                A collapse that keeps rewriting its own result never converges.
                """
            )

            let removedIDs = Set(byID.keys).subtracting(survivingIDs)
            for id in removedIDs {
                for entry in byID[id] ?? [] { modelContext.delete(entry.row) }
            }
            for survivor in survivors {
                let existing = byID[survivor.id] ?? []
                if existing.isEmpty {
                    // A survivor the collapse synthesized under an ID that was
                    // not on disk. Insert it rather than dropping it silently.
                    modelContext.insert(try M(from: survivor))
                } else {
                    for entry in existing where entry.domain != survivor {
                        try entry.row.update(from: survivor)
                    }
                }
            }

            // Survivors are chosen from disk, not from state: a foreign write.
            modelContext.author = nil
            try modelContext.save()
            let outcome = CollapseOutcome(
                survivors: survivors,
                removedIDs: removedIDs,
                duplicateRowCount: rows.count - byID.count
            )
            return (outcome, undecodable)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Fetches every existing row whose ID is in `ids`, grouped by ID, in
    /// chunks of ``batchFetchChunkSize``.
    ///
    /// The value is an array, not a single model: grouping with `byID[id] = row`
    /// would silently drop every duplicate but the last, so a write would land
    /// on one arbitrary row and a deletion would leave the others behind.
    private func rowsByID<M: PersistableModel>(
        _ ids: Set<UUID>,
        as type: M.Type
    ) throws -> [UUID: [M]] {
        var byID: [UUID: [M]] = [:]
        for model in try rows(ids: ids, as: M.self) {
            byID[model.id, default: []].append(model)
        }
        return byID
    }

    /// Every existing row whose ID is in `ids`, in fetch order, fetched in
    /// chunks of ``batchFetchChunkSize``.
    ///
    /// The one place a by-ID fetch is issued — the read path collapses these to
    /// domain values, the write path groups them by ID. Order is preserved so
    /// "first row in fetch order wins" means the same thing to both.
    private func rows<M: PersistableModel>(
        ids: some Sequence<UUID>,
        as type: M.Type
    ) throws -> [M] {
        var rows: [M] = []
        for chunk in Self.idChunks(ids) {
            // Per-model descriptor, not a generic `#Predicate` — see `swiduxBatchFetchDescriptor`.
            rows.append(contentsOf: try modelContext.fetch(M.swiduxBatchFetchDescriptor(ids: chunk)))
        }
        return rows
    }

    /// Splits `ids` into fetch-sized chunks, deduplicated, in the order given.
    ///
    /// Kept separate from the fetch so the batching claim — one round trip per
    /// ``batchFetchChunkSize`` IDs, whatever the table holds — is directly
    /// testable. There is no seam to count `ModelContext` fetches.
    ///
    /// Order is preserved rather than normalised through a `Set`: which chunk an
    /// ID lands in decides where its row appears in the result, and `Set`
    /// iteration is seeded per process. Deduplicating through one would make a
    /// read of more than ``batchFetchChunkSize`` IDs come back in a different
    /// order on every launch, and a merge append its new rows accordingly.
    static func idChunks(_ ids: some Sequence<UUID>) -> [[UUID]] {
        chunks(ids)
    }

    /// ``idChunks(_:)`` for any identifier type — the history scan chunks
    /// `PersistentIdentifier`s through the same rule, and one chunk size with
    /// two implementations is one too many.
    static func chunks<ID: Hashable>(_ ids: some Sequence<ID>) -> [[ID]] {
        var seen = Set<ID>()
        let unique = ids.filter { seen.insert($0).inserted }
        return stride(from: 0, to: unique.count, by: batchFetchChunkSize).map {
            Array(unique[$0..<min($0 + batchFetchChunkSize, unique.count)])
        }
    }
}

/// A read's rows, collapsed to one domain value per `id`.
struct CollapsedRead<Domain: Sendable>: Sendable {
    /// One value per decodable `id`, in fetch order.
    var domains: [Domain]

    /// How many rows shared an `id` with an earlier one and were collapsed away.
    var duplicatesCollapsed: Int

    /// The rows that could not be decoded, and so are not in ``domains``.
    var undecodable: UndecodableRows

    /// ``domains``, or the first decoding error — for callers with no way to
    /// say that a row was skipped.
    func checked() throws -> [Domain] {
        try undecodable.check()
        return domains
    }
}

/// Stored rows a read found but could not turn into domain values.
///
/// Kept apart from a failed fetch on purpose. A fetch that throws read nothing,
/// so nothing it returns can be trusted; a row that will not decode costs that
/// row alone, and the read around it is as good as any other.
struct UndecodableRows: Sendable {
    /// The IDs that would not decode.
    private(set) var ids: Set<UUID> = []

    /// The first decoding error met, in fetch order.
    private(set) var firstError: (any Error)?

    mutating func record(_ id: UUID, _ error: any Error) {
        ids.insert(id)
        if firstError == nil { firstError = error }
    }

    /// Throws the first decoding error, if any row failed.
    func check() throws {
        if let firstError { throw firstError }
    }
}
