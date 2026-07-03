//
//  RemoteChangeObserver.swift
//  SwiduxCloudKitSync
//
//  Observes CloudKit-driven store changes and triggers a debounced, merge-based
//  re-hydration. `.NSPersistentStoreRemoteChange` fires for the app's own local
//  saves too; because re-hydration always *merges* preferring in-memory state,
//  feeding the app its own writes is a no-op — the rule-#8 data-loss trap is
//  neutralized by construction rather than by discipline.
//

import Foundation
import os

/// Watches for remote store changes and invokes a debounced re-hydrate handler.
@MainActor
public final class RemoteChangeObserver {
    private let debounce: Duration
    private let onRemoteChange: @MainActor () async -> Void
    private let logger: Logger
    private var observerToken: (any NSObjectProtocol)?
    private var pending: Task<Void, Never>?

    /// Creates an observer with a debounce window and re-hydrate handler.
    public init(
        debounce: Duration = .seconds(2),
        logger: Logger = Logger(subsystem: "swidux", category: "sync"),
        onRemoteChange: @escaping @MainActor () async -> Void
    ) {
        self.debounce = debounce
        self.onRemoteChange = onRemoteChange
        self.logger = logger
    }

    /// Begins observing `.NSPersistentStoreRemoteChange`. Safe to call once.
    public func start() {
        guard observerToken == nil else { return }
        observerToken = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleMerge()
            }
        }
    }

    /// Stops observing and cancels any pending merge. Called before a container
    /// rebuild / sync toggle.
    public func stop() {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
            observerToken = nil
        }
        pending?.cancel()
        pending = nil
    }

    private func scheduleMerge() {
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            await self.onRemoteChange()
        }
    }

    /// Test seam: `true` once a remote-change notification has armed a debounced
    /// merge (and until `stop()` clears it). Notification delivery is async on the
    /// main queue, so tests poll this to know the debounce is scheduled instead of
    /// guessing a fixed delay.
    var hasScheduledMerge: Bool { pending != nil }
}
