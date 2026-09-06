//
//  SwiduxRelationCodec.swift
//  SwiduxPersistence
//
//  Relationship write-back for macro-generated models. Emitted into `@Persisted`
//  model `update(from:)` bodies for `@Relation` properties, exactly as
//  `SwiduxInlineCodec` is emitted into `@Inline` accessors.
//

import Foundation
import SwiftData

/// Reconciles a generated model's `@Relation` properties against the domain
/// value being written. Not meant to be called directly.
///
/// ## Why a converter can't just rebuild its children
///
/// The obvious `update(from:)` body — `self.chapters = try domain.chapters.map {
/// try ChapterModel(from: $0) }` — is a row leak. A relationship's `deleteRule`
/// fires when the *parent* is deleted, never when a child is dropped from the
/// relationship, so the previously-related rows are detached rather than
/// removed: they stay in the store with no owner, and nothing ever collects
/// them. Every save of the parent leaves another full copy of its children
/// behind, the store grows for the life of the app, and `toDomain()` — which
/// only walks the current relationship — shows nothing wrong.
///
/// So the write-back reconciles by `id` instead: rows whose identity survives
/// are updated in place, new identities are inserted, and identities that are
/// gone are deleted outright.
///
/// ## Identity, not row identity
///
/// Reconciling in place also keeps `persistentModelID` stable across a save.
/// That matters beyond tidiness: a rebuilt child is a delete plus an insert, so
/// under CloudKit mirroring every parent edit re-uploads its whole subtree, and
/// every one of those writes a history transaction that a remote-change tick
/// then has to resolve.
///
/// ## Duplicates are kept, as everywhere else
///
/// `@Persisted` emits no `@Attribute(.unique)` on `id` (CloudKit forbids unique
/// constraints), so several related rows may legitimately share one identity.
/// They are all updated and all kept, matching ``EntityDB``: converging every
/// matching row is safe, while picking one survivor is not — two devices pick
/// different rows, each tombstones the other's, and both are lost.
public enum SwiduxRelationCodec {
    /// Reconciles a to-many relationship against `domain`.
    ///
    /// - Parameters:
    ///   - existing: The rows currently related, as the generated (always
    ///     optional, for CloudKit) property holds them.
    ///   - domain: The domain values that should be related after this write.
    ///   - context: The model's context, used to delete rows whose identity is
    ///     gone. `nil` for a model not yet inserted, where there is nothing on
    ///     disk to delete.
    /// - Returns: The rows to assign back to the relationship.
    /// - Throws: A model conversion error. The caller must roll back the enclosing write.
    public static func reconcile<M: PersistableModel>(
        _ existing: [M]?,
        with domain: [M.Domain],
        in context: ModelContext?
    ) throws -> [M] {
        guard let existing, !existing.isEmpty else {
            return try domain.map { try M(from: $0) }
        }

        var byID: [UUID: [M]] = [:]
        for row in existing { byID[row.id, default: []].append(row) }

        var survivors: [M] = []
        survivors.reserveCapacity(max(existing.count, domain.count))
        var keptIDs = Set<UUID>(minimumCapacity: domain.count)

        for value in domain {
            guard let rows = byID[value.id], !rows.isEmpty else {
                survivors.append(try M(from: value))
                continue
            }
            // Every row sharing the identity, so duplicates converge rather
            // than leaving a stale copy behind the one we happened to pick.
            for row in rows { try row.update(from: value) }
            // Recorded once: a domain array naming the same id twice must not
            // append its rows twice.
            if keptIDs.insert(value.id).inserted {
                survivors.append(contentsOf: rows)
            }
        }

        for (id, rows) in byID where !keptIDs.contains(id) {
            for row in rows { context?.delete(row) }
        }
        return survivors
    }

    /// Reconciles a to-one relationship against `domain`.
    ///
    /// Same rules as the to-many form: a matching identity is updated in place,
    /// and one that is gone — replaced or cleared — is deleted rather than
    /// merely detached.
    public static func reconcile<M: PersistableModel>(
        _ existing: M?,
        with domain: M.Domain?,
        in context: ModelContext?
    ) throws -> M? {
        guard let domain else {
            if let existing { context?.delete(existing) }
            return nil
        }
        if let existing {
            if existing.id == domain.id {
                try existing.update(from: domain)
                return existing
            }
            context?.delete(existing)
        }
        return try M(from: domain)
    }
}
