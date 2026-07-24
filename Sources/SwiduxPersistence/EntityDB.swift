//
//  EntityDB.swift
//  SwiduxPersistence
//
//  One generic SwiftData actor that replaces the per-type `{Type}DB` actors
//  apps hand-write. Drives fetch/upsert/delete for any generated shadow model.
//

import Foundation
import SwiftData

/// A generic `@ModelActor` that reads and writes any ``PersistableModel``.
///
/// Off the main actor; all access goes through its `ModelContext`. The
/// persistence plugin calls `upsert`/`delete` from the debounced flush and
/// `fetchAll` during hydration / re-hydration.
@ModelActor
public actor EntityDB {
    /// Loads every persisted row of `M` and reconstructs domain values.
    public func fetchAll<M: PersistableModel>(_ type: M.Type) throws -> [M.Domain] {
        try modelContext.fetch(FetchDescriptor<M>()).map { $0.toDomain() }
    }

    /// Inserts or updates the row for `domain.id`, then saves.
    ///
    /// Convenience single-row API (used by tests and one-off tooling). The
    /// plugin's flush path uses ``apply(writes:deletions:as:)``, which batches
    /// everything into a single transaction — prefer it for multi-row changes,
    /// since a sequence of single-row saves can be interrupted part-way.
    public func upsert<M: PersistableModel>(_ domain: M.Domain, as type: M.Type) throws {
        if let existing = try fetchByID(domain.id, as: M.self) {
            existing.update(from: domain)
        } else {
            modelContext.insert(M(from: domain))
        }
        try modelContext.save()
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
    /// On failure the context is rolled back before rethrowing, leaving no
    /// half-applied changes behind for a later save to pick up.
    public func apply<M: PersistableModel>(
        writes: [M.Domain],
        deletions: Set<UUID>,
        as type: M.Type
    ) throws {
        do {
            let touchedIDs = Set(writes.map(\.id)).union(deletions)
            var existingByID = try fetchByIDs(touchedIDs, as: M.self)
            for domain in writes {
                if let existing = existingByID[domain.id] {
                    existing.update(from: domain)
                } else {
                    let inserted = M(from: domain)
                    modelContext.insert(inserted)
                    // Keep the map faithful to context state: a later
                    // deletion of the same ID must see the pending row,
                    // exactly as a per-ID fetch would.
                    existingByID[domain.id] = inserted
                }
            }
            for id in deletions {
                if let existing = existingByID[id] {
                    modelContext.delete(existing)
                }
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Deletes the row for `id` if present, then saves.
    ///
    /// Convenience single-row API — see ``apply(writes:deletions:as:)`` for
    /// the transactional batch path the plugin uses.
    public func delete<M: PersistableModel>(id: UUID, as type: M.Type) throws {
        guard let existing = try fetchByID(id, as: M.self) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private func fetchByID<M: PersistableModel>(_ id: UUID, as type: M.Type) throws -> M? {
        // Per-model descriptor, not a generic `#Predicate` here — see `swiduxFetchDescriptor`.
        try modelContext.fetch(M.swiduxFetchDescriptor(id: id)).first
    }

    /// Fetches every existing row whose ID is in `ids`, keyed by ID, in
    /// chunks of ``batchFetchChunkSize``.
    private func fetchByIDs<M: PersistableModel>(
        _ ids: Set<UUID>,
        as type: M.Type
    ) throws -> [UUID: M] {
        var byID: [UUID: M] = [:]
        let allIDs = Array(ids)
        var start = 0
        while start < allIDs.count {
            let chunk = Array(allIDs[start..<min(start + Self.batchFetchChunkSize, allIDs.count)])
            // Per-model descriptor, not a generic `#Predicate` — see `swiduxBatchFetchDescriptor`.
            for model in try modelContext.fetch(M.swiduxBatchFetchDescriptor(ids: chunk)) {
                byID[model.id] = model
            }
            start += Self.batchFetchChunkSize
        }
        return byID
    }
}
