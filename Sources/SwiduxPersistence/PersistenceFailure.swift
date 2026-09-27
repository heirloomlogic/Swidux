//
//  PersistenceFailure.swift
//  SwiduxPersistence
//
//  Surfaced when a persistence operation fails instead of being silently
//  swallowed — the difference between "saved" and "looked saved".
//

import Foundation
import Swidux

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

    /// The rows this failure is confined to, when it is confined to some.
    ///
    /// A save that failed for some rows and not others — a value that can
    /// never be encoded, such as a non-finite `Double` in an `@Inline`
    /// payload — names exactly those rows, and every other row in its batch
    /// reached storage. Empty when the operation failed as a whole; the
    /// accumulated set of writes still off disk is
    /// ``PersistenceDiagnostic/Kind/writesUnpersisted``.
    public let failedIDs: Set<UUID>

    /// Creates a failure record.
    public init(
        operation: Operation,
        entityType: String,
        underlying: any Error,
        isFinal: Bool = false,
        failedIDs: Set<UUID> = []
    ) {
        self.operation = operation
        self.entityType = entityType
        self.underlying = underlying
        self.isFinal = isFinal
        self.failedIDs = failedIDs
    }

    /// A failed save of `entityType`, naming the rows it was confined to when
    /// it was confined to some.
    ///
    /// A partial failure is unwrapped to the conversion error behind it,
    /// because that — not the wrapper — is what an app can act on.
    static func save(_ error: any Error, entityType: String, isFinal: Bool = false) -> Self {
        Self(
            operation: .save, entityType: entityType,
            underlying: (error as? UnencodableRows)?.underlying ?? error, isFinal: isFinal,
            failedIDs: (error as? any PartialPersistFailure)?.failedIDs ?? [])
    }
}

/// Some rows of a write batch could not be converted to their stored form.
///
/// Thrown by ``EntityDB/apply(writes:deletions:as:)`` after it has saved every
/// **other** row of the batch. A conversion failure is deterministic — the same
/// value fails the same way on every attempt — so rolling the whole batch back
/// would only hold every unrelated row back with the one that can never save.
public struct UnencodableRows: PartialPersistFailure {
    /// The IDs whose value could not be converted, and so were not saved.
    public let failedIDs: Set<UUID>

    /// The first conversion error, in batch order.
    public let underlying: any Error

    /// Creates the error for `failedIDs`, carrying the first error met.
    public init(failedIDs: Set<UUID>, underlying: any Error) {
        self.failedIDs = failedIDs
        self.underlying = underlying
    }
}

/// Receives ``PersistenceFailure`` values from the persistence stack.
public typealias PersistenceFailureHandler = @Sendable (PersistenceFailure) -> Void
