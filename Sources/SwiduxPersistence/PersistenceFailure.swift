//
//  PersistenceFailure.swift
//  SwiduxPersistence
//
//  Surfaced when a persistence operation fails instead of being silently
//  swallowed — the difference between "saved" and "looked saved".
//

import Foundation

/// A persistence operation that failed.
///
/// Delivered to ``PersistenceCoordinator``'s `onFailure` handler (always after
/// being logged). Writes that fail stay visible in memory but are **not** on
/// disk; a fetch that fails leaves the corresponding `EntityStore` untouched.
public struct PersistenceFailure: Sendable {
    /// Which kind of operation failed.
    public enum Operation: Sendable {
        /// A debounced flush batch (upserts and/or deletions) failed to save.
        case save
        /// A hydration / re-hydration fetch failed.
        case fetch
    }

    /// The operation that failed.
    public let operation: Operation
    /// The domain entity type involved, e.g. `"Card"`.
    public let entityType: String
    /// The underlying SwiftData / storage error.
    public let underlying: any Error

    /// Whether the stack has stopped retrying this write.
    ///
    /// A failed save is retried on a bounded backoff, so most `.save` failures
    /// arrive with this `false` and are followed by a successful attempt the
    /// app never hears about. `true` means the retry budget is spent: the value
    /// is still in memory and still protected from being overwritten by the
    /// stale stored row, but it is **not** on disk and nothing further will be
    /// attempted until the entity is edited again or the app flushes
    /// explicitly. This is the one worth telling the user about.
    ///
    /// Always `false` for `.fetch`, which is not retried.
    public let isFinal: Bool

    /// Creates a failure record.
    public init(
        operation: Operation,
        entityType: String,
        underlying: any Error,
        isFinal: Bool = false
    ) {
        self.operation = operation
        self.entityType = entityType
        self.underlying = underlying
        self.isFinal = isFinal
    }
}

/// Receives ``PersistenceFailure`` values from the persistence stack.
public typealias PersistenceFailureHandler = @Sendable (PersistenceFailure) -> Void
