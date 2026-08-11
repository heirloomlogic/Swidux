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

/// A thread-safe holder for the currently active ``EntityDB``, and for the
/// merge anchor that only makes sense against it.
///
/// Persist/hydrate closures read `db` at call time, so swapping it (after a
/// flush) redirects all subsequent reads and writes to a new container.
public final class DatabaseHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: EntityDB

    /// How many times `db` has been replaced. A merge reads it before its first
    /// fetch and quotes it back when installing an anchor, so a swap that
    /// happens mid-merge invalidates the anchor the merge computed.
    private var generation = 0

    /// The newest history token a merge has offered in full, and the rows it
    /// offered but declined to apply.
    ///
    /// One value because they are one fact: "everything up to `token` has been
    /// offered, except `carryOver`". A token on its own would claim a withheld
    /// row was consumed. Both are discarded together when `db` is replaced — a
    /// token means nothing to a store that didn't issue it, and neither do
    /// identities resolved against it.
    private var installed: (token: DefaultHistoryToken, carryOver: AttributedIDs)?

    /// Creates a handle wrapping an initial ``EntityDB``.
    public init(_ db: EntityDB) {
        storage = db
    }

    /// The active database. Reads and writes are serialized by an internal lock;
    /// the held value is an `actor` reference, so callers `await` its methods.
    ///
    /// Replacing it discards the anchor. A token is only meaningful for the
    /// store that issued it, and a stale one is not inert: the fetch it anchors
    /// returns *zero transactions with no error*, which is indistinguishable
    /// from "nothing changed", so merging would stop permanently and silently.
    public var db: EntityDB {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            installed = nil
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

    /// The current anchor — watermark and outstanding rows — and the generation
    /// it belongs to.
    ///
    /// Callers read all three together and quote the generation back when they
    /// install, so the set can't be torn by a swap between reads.
    var anchor: (token: DefaultHistoryToken?, carryOver: AttributedIDs, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (installed?.token, installed?.carryOver ?? AttributedIDs(), generation)
    }

    /// Records what a tick accounted for: the window it consumed, and the rows
    /// within it that it read but declined to apply.
    ///
    /// Each half is optional and `nil` means "leave it alone", because the two
    /// move independently. A tick can consume a window without offering a row to
    /// anything — first-load hydration, or transactions that touched no mirrored
    /// model — and so cannot settle a debt. A tick can also settle one without
    /// consuming any new window, which is the shape of the tick that finally
    /// delivers a row after its hold lifts, since lifting a hold writes no
    /// transaction of its own.
    ///
    /// Refuses in two cases. A `generation` older than the current one means the
    /// container was swapped while the merge was suspended, so `token` describes
    /// a store this handle no longer points at. A `token` no newer than the one
    /// held means two ticks overlapped and this is the slower one — installing it
    /// would rewind the anchor and re-merge a window that has already landed.
    ///
    /// - Parameters:
    ///   - token: The newest token the tick consumed.
    ///   - carryOver: What is still owed. Replaces rather than accumulates: the
    ///     tick recomputed withholding against everything it was offered, which
    ///     included everything the last one deferred.
    ///   - generation: The generation the tick read before it started.
    /// - Returns: Whether the anchor moved.
    @discardableResult
    func installAnchor(
        watermark token: DefaultHistoryToken?,
        carryOver: AttributedIDs?,
        ifGeneration generation: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return false }
        guard let token else {
            // No window to advance past, so there is only a debt to update — and
            // with no anchor there is nowhere to attach one. None is owed there
            // either: an unanchored session re-reads everything next tick.
            guard installed != nil, let carryOver else { return false }
            installed?.carryOver = carryOver
            return true
        }
        if let current = installed?.token, token <= current { return false }
        installed = (token, carryOver ?? installed?.carryOver ?? AttributedIDs())
        return true
    }
}
