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

    /// The newest history token a merge has offered in full.
    private var watermark: DefaultHistoryToken?

    /// Changes whenever a tick installs history accounting.
    private var revision: UInt64 = 0

    /// The rows a merge was offered and declined to apply, still owed.
    ///
    /// Stored beside the watermark rather than inside it, because the two are
    /// not one fact. A watermark describes a *window* this coordinator consumed;
    /// a debt describes *identities*, and a caller-fed merge incurs one without
    /// consuming any window at all. Pinning the debt to the token would mean a
    /// path with no window of its own could never record what it owes.
    ///
    /// What they do share is the store the identities were resolved against, so
    /// both are discarded when `db` is replaced — a token means nothing to a
    /// store that didn't issue it, and neither do identities resolved against it.
    private var outstanding = AttributedIDs()

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
            watermark = nil
            outstanding = AttributedIDs()
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

    /// The current history accounting and the generation and revision it belongs to.
    /// Callers capture this before reading and quote both counters when installing.
    var anchor: (token: DefaultHistoryToken?, carryOver: AttributedIDs, generation: Int, revision: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (watermark, outstanding, generation, revision)
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
    /// Refuses accounting from a replaced database or an older revision. The
    /// revision detects a tick that suspended while another tick committed,
    /// including commits that changed only outstanding rows. History tokens are
    /// opaque; their in-memory comparison need not follow transaction order.
    ///
    /// - Parameters:
    ///   - token: The newest token the tick consumed, or `nil` for a tick that
    ///     consumed no window of its own — either a caller-fed merge, or the one
    ///     that finally delivers a row after its hold lifts.
    ///   - carryOver: What is still owed. Replaces rather than accumulates,
    ///     which is sound because every path that records one first re-offers
    ///     everything already owed — so the tick recomputed withholding against
    ///     its own news *and* the last tick's deferrals together.
    ///   - generation: The generation the tick read before it started.
    ///   - revision: The accounting revision the tick read before it started.
    /// - Returns: Whether the accounting was accepted.
    @discardableResult
    func installAnchor(
        watermark token: DefaultHistoryToken?,
        carryOver: AttributedIDs?,
        ifGeneration generation: Int,
        ifRevision revision: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, revision == self.revision else { return false }
        guard token != nil || carryOver != nil else { return false }
        if let token { watermark = token }
        if let carryOver { outstanding = carryOver }
        self.revision &+= 1
        return true
    }
}
