//
//  RemoteChangeObserver.swift
//  SwiduxCloudKitSync
//
//  Observes CloudKit-driven store changes and triggers a debounced, merge-based
//  re-hydration. `.NSPersistentStoreRemoteChange` fires for the app's own local
//  saves too, and feeding the app its own writes is a no-op: an echoed write is
//  equal to the row already in memory, so reconciling against it changes
//  nothing. Anything still unflushed is protected separately, by the merge's
//  dirty set — so the rule-#8 data-loss trap is neutralized by construction
//  rather than by discipline.
//
//  The observer registers with `object: nil`, so it receives the notification
//  for every store in the process — SwiftData surfaces no coordinator to narrow
//  the registration with. Telling the observer which stores it owns lets it
//  drop the rest; being unable to identify a store never drops it.
//

import CoreData
import Foundation
import SwiduxPersistence
import os

/// Watches for remote store changes and invokes a debounced re-hydrate handler.
@MainActor
public final class RemoteChangeObserver {
    /// The stores this observer is responsible for, re-read on every
    /// notification, or `nil` to accept every store in the process.
    ///
    /// Re-read rather than captured because toggling sync rebuilds the
    /// container, and a set snapshotted at init would describe a store that is
    /// no longer the active one. Internal: the public initializer takes the
    /// ``SwiduxPersistence/DatabaseHandle`` this is derived from.
    typealias StoreIdentity = @MainActor () -> Set<URL>

    private let debounce: Duration
    private let onRemoteChange: @MainActor (RemoteChange) async -> Void
    private let ownedStoreURLs: StoreIdentity?
    private let logger: Logger
    private let notificationCenter: NotificationCenter
    private var observerToken: (any NSObjectProtocol)?
    private var pending: Task<Void, Never>?

    /// The accepted notifications seen since the last callback fired, or `nil`
    /// when none are owed. Accumulated in the payload's own type: a separate
    /// builder would be the same four fields declared twice, kept in step by
    /// hand.
    private var burst: RemoteChange?

    /// The designated initializer. `notificationCenter` is a test seam.
    ///
    /// `.NSPersistentStoreRemoteChange` is posted to the process-wide
    /// `NotificationCenter.default`, which in a test bundle also carries the
    /// saves of every other suite's `ModelContainer`. A test that asserts on
    /// *how many* notifications a burst held cannot get a stable answer from a
    /// shared center, so tests hand in one of their own.
    init(
        debounce: Duration = .seconds(2),
        ownedStoreURLs: StoreIdentity? = nil,
        logger: Logger = Logger(subsystem: "swidux", category: "sync"),
        notificationCenter: NotificationCenter,
        onRemoteChange: @escaping @MainActor (RemoteChange) async -> Void
    ) {
        self.debounce = debounce
        self.ownedStoreURLs = ownedStoreURLs
        self.onRemoteChange = onRemoteChange
        self.logger = logger
        self.notificationCenter = notificationCenter
    }

    /// Creates an observer with a debounce window and re-hydrate handler.
    ///
    /// - Parameters:
    ///   - debounce: How long to coalesce a burst of notifications before
    ///     calling the handler once.
    ///   - handle: The database whose stores this observer is responsible for.
    ///     Consulted per notification, so a sync toggle — which rebuilds the
    ///     container behind the same handle — is picked up without re-creating
    ///     the observer. `nil` accepts every store in the process, which is
    ///     correct but does needless work for stores the app doesn't own.
    ///   - logger: Logger for dropped notifications.
    ///   - onRemoteChange: Called once per coalesced burst, with the stores it
    ///     named.
    public convenience init(
        debounce: Duration = .seconds(2),
        owning handle: DatabaseHandle? = nil,
        logger: Logger = Logger(subsystem: "swidux", category: "sync"),
        onRemoteChange: @escaping @MainActor (RemoteChange) async -> Void
    ) {
        var identity: StoreIdentity?
        if let handle { identity = { handle.storeURLs } }
        self.init(
            debounce: debounce,
            ownedStoreURLs: identity,
            logger: logger,
            notificationCenter: .default,
            onRemoteChange: onRemoteChange
        )
    }

    /// Begins observing `.NSPersistentStoreRemoteChange`. Safe to call once.
    public func start() {
        guard observerToken == nil else { return }
        observerToken = notificationCenter.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Read out here, where the `Notification` is: only the two Sendable
            // values it yields need to reach the main actor.
            let userInfo = notification.userInfo
            let storeURL = (userInfo?[NSPersistentStoreURLKey] as? URL)?.standardizedFileURL
            let storeUUID = userInfo?[NSStoreUUIDKey] as? String
            MainActor.assumeIsolated {
                self?.record(storeURL: storeURL, storeUUID: storeUUID)
            }
        }
    }

    /// Stops observing and cancels any pending merge. Called before a container
    /// rebuild / sync toggle.
    public func stop() {
        if let token = observerToken {
            notificationCenter.removeObserver(token)
            observerToken = nil
        }
        pending?.cancel()
        pending = nil
        // The burst goes with the merge that would have reported it. Keeping it
        // would fold stores observed before a container rebuild into the first
        // burst after one.
        burst = nil
    }

    /// Folds one notification into the current burst, unless it belongs to a
    /// store this observer doesn't own.
    private func record(storeURL: URL?, storeUUID: String?) {
        guard accepts(storeURL) else {
            // Dropped, and so not re-armed either: a notification that
            // contributes nothing to the burst must not extend the window the
            // burst is waiting on, or a store being ignored could hold off the
            // merge indefinitely.
            logger.debug("Ignoring a remote change from a store this observer doesn't own.")
            return
        }

        // Mutated through the optional rather than copied out and back, so the
        // accumulated sets stay uniquely referenced instead of reallocating on
        // every notification.
        if burst == nil { burst = RemoteChange() }
        burst?.notificationCount += 1
        if let storeURL {
            burst?.storeURLs.insert(storeURL)
        } else {
            burst?.includesUnidentifiedStore = true
        }
        if let storeUUID { burst?.storeUUIDs.insert(storeUUID) }

        scheduleMerge()
    }

    /// Whether a notification from `storeURL` should be merged.
    ///
    /// Fails towards merging, twice over: with no identity configured every
    /// store is accepted, and a store that can't be identified is accepted too.
    /// Filtering trades a wasted scan for a silently missed remote change if it
    /// gets this backwards, so "I don't know" must never mean "ignore it".
    private func accepts(_ storeURL: URL?) -> Bool {
        guard let ownedStoreURLs else { return true }
        guard let storeURL else { return true }
        return ownedStoreURLs().contains(storeURL)
    }

    private func scheduleMerge() {
        armedMergeCount += 1
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            await self.fire()
        }
    }

    /// Hands the accumulated burst to the handler and starts a fresh one.
    private func fire() async {
        guard let burst else { return }
        self.burst = nil
        await onRemoteChange(burst)
    }

    /// Test seam: `true` once a remote-change notification has armed a debounced
    /// merge (and until `stop()` clears it). Notification delivery is async on the
    /// main queue, so tests poll this to know the debounce is scheduled instead of
    /// guessing a fixed delay.
    var hasScheduledMerge: Bool { pending != nil }

    /// Test seam: how many times the debounce has been armed or re-armed.
    ///
    /// Lets a test assert that a notification was *dropped* — an absence, which
    /// otherwise only a fixed sleep long enough to outlast the debounce could
    /// observe, and those race CI scheduling.
    private(set) var armedMergeCount = 0
}
