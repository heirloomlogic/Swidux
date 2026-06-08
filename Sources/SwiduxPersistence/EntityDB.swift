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
    public func upsert<M: PersistableModel>(_ domain: M.Domain, as type: M.Type) throws {
        if let existing = try fetchByID(domain.id, as: M.self) {
            existing.update(from: domain)
        } else {
            modelContext.insert(M(from: domain))
        }
        try modelContext.save()
    }

    /// Deletes the row for `id` if present, then saves.
    public func delete<M: PersistableModel>(id: UUID, as type: M.Type) throws {
        guard let existing = try fetchByID(id, as: M.self) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private func fetchByID<M: PersistableModel>(_ id: UUID, as type: M.Type) throws -> M? {
        // Per-model descriptor, not a generic `#Predicate` here — see `swiduxFetchDescriptor`.
        try modelContext.fetch(M.swiduxFetchDescriptor(id: id)).first
    }
}
