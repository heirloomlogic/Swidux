//
//  DatabaseHandle.swift
//  SwiduxPersistence
//
//  An indirection so the active `EntityDB` (and the container behind it) can be
//  swapped at runtime — e.g. when toggling iCloud sync rebuilds the container —
//  without rebuilding the persistence plugin or re-registering writers.
//

import Foundation

/// A thread-safe holder for the currently active ``EntityDB``.
///
/// Persist/hydrate closures read `db` at call time, so swapping it (after a
/// flush) redirects all subsequent reads and writes to a new container.
public final class DatabaseHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: EntityDB

    /// Creates a handle wrapping an initial ``EntityDB``.
    public init(_ db: EntityDB) {
        storage = db
    }

    /// The active database. Reads and writes are serialized by an internal lock;
    /// the held value is an `actor` reference, so callers `await` its methods.
    public var db: EntityDB {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
