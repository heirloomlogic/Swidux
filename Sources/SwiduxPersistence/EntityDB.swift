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

    /// Loads every persisted row of `M` and reconstructs domain values.
    ///
    /// Rows sharing an `id` are collapsed to the first one in fetch order:
    /// ``EntityStore`` cannot represent duplicates, and handing it a duplicate
    /// corrupts its index. Duplicates are logged, not treated as an error —
    /// they are a legitimate state under CloudKit mirroring.
    public func fetchAll<M: PersistableModel>(_ type: M.Type) throws -> [M.Domain] {
        let rows = try modelContext.fetch(FetchDescriptor<M>())
        var seen = Set<UUID>()
        var domains: [M.Domain] = []
        domains.reserveCapacity(rows.count)
        for row in rows where seen.insert(row.id).inserted {
            domains.append(row.toDomain())
        }
        if domains.count < rows.count {
            Self.logger.warning(
                """
                \(String(describing: M.self), privacy: .public): \
                \(rows.count - domains.count, privacy: .public) duplicate row(s) collapsed on read. \
                Register a collapse closure to remove them from disk.
                """
            )
        }
        return domains
    }

    /// Loads every persisted row of the **domain** type `E`.
    ///
    /// The same read as ``fetchAll(_:)``, named by the entity you wrote rather
    /// than by its generated shadow model — `fetchAll(of: Note.self)` instead
    /// of `fetchAll(NoteModel.self)`.
    public func fetchAll<E: PersistableEntity>(of type: E.Type) throws -> [E] {
        try fetchAll(E.Model.self)
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
    /// On failure the context is rolled back before rethrowing, leaving no
    /// half-applied changes behind for a later save to pick up.
    public func apply<M: PersistableModel>(
        writes: [M.Domain],
        deletions: Set<UUID>,
        as type: M.Type
    ) throws {
        do {
            let touchedIDs = Set(writes.map(\.id)).union(deletions)
            var existingByID = try rowsByID(touchedIDs, as: M.self)
            for domain in writes {
                let existing = existingByID[domain.id] ?? []
                if existing.isEmpty {
                    let inserted = M(from: domain)
                    modelContext.insert(inserted)
                    // Keep the map faithful to context state: a later
                    // deletion of the same ID must see the pending row,
                    // exactly as a per-ID fetch would.
                    existingByID[domain.id] = [inserted]
                } else {
                    for row in existing { row.update(from: domain) }
                }
            }
            for id in deletions {
                for row in existingByID[id] ?? [] {
                    modelContext.delete(row)
                }
            }
            try modelContext.save()
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
    /// - Throws: Whatever the underlying fetch or save throws. The context is
    ///   rolled back before rethrowing.
    @discardableResult
    public func collapseDuplicates<M: PersistableModel>(
        as type: M.Type,
        using collapse: @Sendable ([M.Domain]) -> [M.Domain]
    ) throws -> CollapseOutcome<M.Domain> {
        do {
            let rows = try modelContext.fetch(FetchDescriptor<M>())
            // Convert once and keep the domain value beside its row: the
            // write-back below needs it again to skip no-op updates.
            var byID: [UUID: [(row: M, domain: M.Domain)]] = [:]
            var domains: [M.Domain] = []
            domains.reserveCapacity(rows.count)
            for row in rows {
                let domain = row.toDomain()
                domains.append(domain)
                byID[row.id, default: []].append((row, domain))
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
                    modelContext.insert(M(from: survivor))
                } else {
                    for entry in existing where entry.domain != survivor {
                        entry.row.update(from: survivor)
                    }
                }
            }

            try modelContext.save()
            return CollapseOutcome(survivors: survivors, removedIDs: removedIDs)
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
        let allIDs = Array(ids)
        var start = 0
        while start < allIDs.count {
            let chunk = Array(allIDs[start..<min(start + Self.batchFetchChunkSize, allIDs.count)])
            // Per-model descriptor, not a generic `#Predicate` — see `swiduxBatchFetchDescriptor`.
            for model in try modelContext.fetch(M.swiduxBatchFetchDescriptor(ids: chunk)) {
                byID[model.id, default: []].append(model)
            }
            start += Self.batchFetchChunkSize
        }
        return byID
    }
}
