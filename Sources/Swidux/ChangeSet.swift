//
//  ChangeSet.swift
//  Swidux
//
//  The set of entity IDs that were upserted or deleted since the last reset.
//

import Foundation

/// Tracks which entity IDs have been created/updated or deleted.
///
/// Accumulated by `EntityStore` during mutations, drained by `StateWriter`
/// after each reducer call, and cleared automatically.
public nonisolated struct ChangeSet: Sendable, Equatable {
    /// IDs of entities that were inserted or modified.
    public var upserts: Set<UUID> = []

    /// IDs of entities that were removed.
    public var deletions: Set<UUID> = []

    /// True when no changes have been recorded.
    public var isEmpty: Bool { upserts.isEmpty && deletions.isEmpty }

    /// Creates an empty change set with no recorded upserts or deletions.
    public init() {}
}
