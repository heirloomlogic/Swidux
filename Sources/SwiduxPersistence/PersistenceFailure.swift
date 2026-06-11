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

    /// Creates a failure record.
    public init(operation: Operation, entityType: String, underlying: any Error) {
        self.operation = operation
        self.entityType = entityType
        self.underlying = underlying
    }
}

/// Receives ``PersistenceFailure`` values from the persistence stack.
public typealias PersistenceFailureHandler = @Sendable (PersistenceFailure) -> Void
