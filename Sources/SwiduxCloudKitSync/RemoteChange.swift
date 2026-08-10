//
//  RemoteChange.swift
//  SwiduxCloudKitSync
//
//  What one debounced burst of `.NSPersistentStoreRemoteChange` notifications
//  named, in terms an app can act on. `RemoteChangeObserver` accumulates into
//  one of these as the burst arrives and hands it over when the debounce
//  elapses, which is why the setters are internal rather than absent.
//

import Foundation

/// The stores one coalesced burst of remote-change notifications named.
///
/// Every field describes the whole burst, not its last notification. A burst is
/// one window as far as the merge is concerned, and "the last one wins" would
/// silently drop every notification but one — on a debounce that exists
/// precisely because bursts are expected, that is a change quietly going
/// missing rather than a visible failure.
///
/// Only notifications the observer *accepted* are represented. A notification
/// from a store the observer was told it doesn't own is dropped before it gets
/// here; one whose store can't be identified is always accepted, and sets
/// ``includesUnidentifiedStore``.
///
/// ## Why there is no history token
///
/// The underlying notification carries `NSPersistentHistoryTokenKey`, and it is
/// deliberately not surfaced. That value is a CoreData `NSPersistentHistoryToken`;
/// the watermark in `SwiduxPersistence` is a SwiftData `DefaultHistoryToken`,
/// whose only public initializer is `init(from:)` — there is no supported
/// conversion between the two, and SwiftData's interface names no CoreData type
/// at all. Publishing a token that neither Swidux nor an app author can act on
/// would be an invitation to misuse it.
///
/// Nothing is lost by leaving it out: `PersistenceCoordinator.mergeChanges(into:policy:)`
/// anchors its watermark on the highest token in the window it just scanned, so
/// the token it needs is one it already holds.
public struct RemoteChange: Sendable {
    /// The on-disk stores the burst named, from `NSPersistentStoreURLKey`.
    ///
    /// Standardized, so they compare equal to the `url` of a `ModelConfiguration`
    /// standardized the same way. A burst can name stores *and* still set
    /// ``includesUnidentifiedStore``; the two are independent.
    public internal(set) var storeURLs: Set<URL> = []

    /// The store UUIDs the burst named, from `NSStoreUUIDKey`.
    ///
    /// Present for information only — SwiftData exposes no store UUID, so
    /// ``storeURLs`` is the identity the observer actually matches on.
    public internal(set) var storeUUIDs: Set<String> = []

    /// Whether any notification in the burst named no store this observer could
    /// identify.
    ///
    /// Those notifications are merged, never ignored: an unidentifiable store
    /// costs a wasted scan, whereas ignoring it would be a silently missed
    /// remote change.
    public internal(set) var includesUnidentifiedStore = false

    /// How many notifications were accepted into this burst.
    ///
    /// Counts accepted notifications only, so a burst dominated by a store the
    /// observer doesn't own reports the few that were its own.
    public internal(set) var notificationCount = 0

    /// Creates a payload describing one burst.
    ///
    /// Everything defaults to empty, which is what the observer starts a burst
    /// from. Public so an app can build one to test its own handler against.
    public init(
        storeURLs: Set<URL> = [],
        storeUUIDs: Set<String> = [],
        includesUnidentifiedStore: Bool = false,
        notificationCount: Int = 0
    ) {
        self.storeURLs = storeURLs
        self.storeUUIDs = storeUUIDs
        self.includesUnidentifiedStore = includesUnidentifiedStore
        self.notificationCount = notificationCount
    }
}
