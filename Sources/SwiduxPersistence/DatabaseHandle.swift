//
//  DatabaseHandle.swift
//  SwiduxPersistence
//
//  An indirection so the active `EntityDB` (and the container behind it) can be
//  swapped at runtime — e.g. when toggling iCloud sync rebuilds the container —
//  without rebuilding the persistence plugin or re-registering writers.
//

import Foundation
import SwiftData

/// A thread-safe holder for the currently active ``EntityDB``.
///
/// Persist/hydrate closures read `db` at call time, so swapping it (after a
/// flush) redirects all subsequent reads and writes to a new container.
public final class DatabaseHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: EntityDB

    /// How many times `db` has been replaced. A merge reads it before its first
    /// fetch and quotes it back when installing a watermark, so a swap that
    /// happens mid-merge invalidates the anchor the merge computed.
    private var generation = 0

    /// The newest history token a completed merge has fully consumed, and the
    /// database generation it describes.
    private var anchor: (token: DefaultHistoryToken, generation: Int)?

    /// Creates a handle wrapping an initial ``EntityDB``.
    public init(_ db: EntityDB) {
        storage = db
    }

    /// The active database. Reads and writes are serialized by an internal lock;
    /// the held value is an `actor` reference, so callers `await` its methods.
    ///
    /// Replacing it discards the history watermark. A token is only meaningful
    /// for the store that issued it, and a stale one is not inert: the fetch it
    /// anchors returns *zero transactions with no error*, which is
    /// indistinguishable from "nothing changed", so merging would stop
    /// permanently and silently.
    public var db: EntityDB {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            anchor = nil
            generation &+= 1
            lock.unlock()
        }
    }

    /// The on-disk stores behind the active database.
    ///
    /// Standardized, so they compare equal to a `NSPersistentStoreURLKey` value
    /// standardized the same way — which is what lets a remote-change observer
    /// tell a notification from *this* store apart from one belonging to some
    /// other store in the process. Read it per notification rather than once:
    /// swapping `db` can change the answer.
    public var storeURLs: Set<URL> {
        Set(db.modelContainer.configurations.lazy.map(\.url.standardizedFileURL))
    }

    /// The current watermark, and the generation it belongs to.
    ///
    /// Callers read both together and quote the generation back to
    /// ``installWatermark(_:ifGeneration:)``, so the pair can't be torn by a
    /// swap between the two reads.
    var watermark: (token: DefaultHistoryToken?, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (anchor?.token, generation)
    }

    /// Advances the watermark, unless the database moved on without it.
    ///
    /// Refuses in two cases. A `generation` older than the current one means the
    /// container was swapped while the merge was suspended, so `token` describes
    /// a store this handle no longer points at. A `token` no newer than the one
    /// held means two ticks overlapped and this is the slower one — installing it
    /// would rewind the anchor and re-merge a window that has already landed.
    ///
    /// - Returns: Whether the watermark moved.
    @discardableResult
    func installWatermark(_ token: DefaultHistoryToken, ifGeneration generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return false }
        if let current = anchor?.token, token <= current { return false }
        anchor = (token, generation)
        return true
    }
}
