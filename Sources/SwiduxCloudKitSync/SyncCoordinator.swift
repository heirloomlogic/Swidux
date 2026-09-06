//
//  SyncCoordinator.swift
//  SwiduxCloudKitSync
//
//  Owns the runtime sync toggle. SwiftData fixes `cloudKitDatabase` at container
//  creation, so toggling rebuilds the container and swaps the active database
//  behind the `PersistenceCoordinator`'s `DatabaseHandle` — never moving local
//  rows (both modes share the same store URL).
//

import Foundation
import Swidux
import SwiduxPersistence
import SwiftData
import os

/// Drives opt-in/opt-out iCloud sync at runtime on top of a
/// ``PersistenceCoordinator``.
@MainActor
public final class SyncCoordinator<State, Action> {
    /// Builds the `ModelContainer` for a given sync mode. The default routes
    /// through `CloudContainerFactory`; inject a custom builder for app-group
    /// stores, migration options, or tests.
    public typealias ContainerBuilder = (SyncMode) throws -> ModelContainer

    private let persistence: PersistenceCoordinator<State, Action>
    private let preflight: SyncPreflightService
    private let keyValue: any KeyValueStore
    private let makeContainer: ContainerBuilder
    private let logger: Logger
    private var toggleRevision: UInt64 = 0

    /// The user's currently-chosen mode (persisted).
    public private(set) var mode: SyncMode

    /// Creates a coordinator over an existing ``PersistenceCoordinator``.
    ///
    /// - Parameters:
    ///   - persistence: The coordinator whose database is swapped on toggle.
    ///   - models: The generated `{Type}Model` types for the schema.
    ///   - mode: The mode resolved at launch (see `resolveDesiredSyncMode`).
    ///   - preflight: iCloud availability probe.
    ///   - keyValue: Store for persisting the user's sync choice.
    ///   - storeURL: Shared on-disk store URL for both modes.
    ///   - cloudKitContainerID: Explicit CloudKit container id, or `nil` for `.automatic`.
    ///   - makeContainer: Custom container builder. Defaults to `CloudContainerFactory`.
    ///   - logger: Logger for rebuild failures.
    public init(
        persistence: PersistenceCoordinator<State, Action>,
        models: [any PersistentModel.Type],
        mode: SyncMode,
        preflight: SyncPreflightService,
        keyValue: any KeyValueStore,
        storeURL: URL? = nil,
        cloudKitContainerID: String? = nil,
        makeContainer: ContainerBuilder? = nil,
        logger: Logger = Logger(subsystem: "swidux", category: "sync")
    ) {
        self.persistence = persistence
        self.mode = mode
        self.preflight = preflight
        self.keyValue = keyValue
        self.makeContainer =
            makeContainer
            ?? { mode in
                try CloudContainerFactory.makeContainer(
                    models: models, mode: mode, url: storeURL, cloudKitContainerID: cloudKitContainerID)
            }
        self.logger = logger
    }

    /// Resolves the current runtime status without changing anything.
    public func currentStatus() async -> SyncStatus {
        while true {
            let revision = toggleRevision
            let desired = mode
            let status = await preflight.resolve(desired: desired)
            if revision == toggleRevision, desired == mode { return status }
        }
    }

    /// The outcome of everything the toggle does before any state is touched.
    private enum TogglePreparation {
        case rebuildFailed
        case superseded
        case ready(SyncStatus, revision: UInt64)
    }

    /// Flush, preflight, container rebuild, preference write — the whole
    /// toggle except the re-hydration. Holds no state across its `await`s.
    private func prepareToggle(_ enabled: Bool) async -> TogglePreparation {
        toggleRevision &+= 1
        let revision = toggleRevision
        let target: SyncMode = enabled ? .iCloud : .localOnly

        // 1. Drain the debounce window so no buffered write is lost on rebuild.
        await persistence.corePlugin.flush()
        guard revision == toggleRevision else { return .superseded }

        // 2. Resolve availability for the requested mode.
        let status = await preflight.resolve(desired: target)
        guard revision == toggleRevision else { return .superseded }

        if status == .misconfiguredNoEntitlement {
            logger.error("iCloud sync requested but the app is not entitled; staying local-only.")
            assertionFailure("SwiduxCloudKitSync: iCloud requested but no iCloud entitlement is present.")
        }

        // 3. Use CloudKit only when it is actually usable; otherwise local.
        let effectiveMode: SyncMode = (target == .iCloud && status == .syncing) ? .iCloud : .localOnly
        guard rebuildDatabase(mode: effectiveMode) else {
            // The old database stays active. Don't persist the choice or
            // report the preflight status — the toggle did not take effect.
            return .rebuildFailed
        }

        // 4. Persist the user's *choice* (not the fallback) for next launch.
        keyValue.setValue(target, for: .syncMode)
        mode = target

        return .ready(enabled ? status : .localOnlyByChoice, revision: revision)
    }

    /// Swaps the active database to a freshly built container.
    ///
    /// Returns `false` (leaving the previous database active) when the
    /// container cannot be built.
    private func rebuildDatabase(mode: SyncMode) -> Bool {
        do {
            persistence.handle.db = EntityDB(modelContainer: try makeContainer(mode))
            return true
        } catch {
            logger.error(
                "Failed to rebuild \(String(describing: mode)) container: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

extension SyncCoordinator where State: SwiduxObservable {
    /// Turns iCloud sync on or off.
    ///
    /// Flushes pending writes, rebuilds the container in the effective mode
    /// (CloudKit only when actually available, else a local fallback), swaps the
    /// active database, persists the preference, and re-hydrates via `merge`
    /// (never replace). Returns the resolved ``SyncStatus``.
    ///
    /// The flush, preflight, and rebuild all complete before any state is
    /// packed, so an edit made while the toggle is in flight survives it.
    /// A newer toggle supersedes an older request still awaiting I/O. A
    /// superseded call returns the current status without restoring its choice.
    ///
    /// Record the result with a normal dispatch afterwards — nothing can
    /// interleave on the main actor in between:
    ///
    /// ```swift
    /// let status = await sync.setSyncEnabled(isOn, into: store)
    /// store.send(.syncSettingsChanged(mode: sync.mode, status: status))
    /// ```
    @discardableResult
    public func setSyncEnabled(_ enabled: Bool, into store: Store<State, Action>) async -> SyncStatus {
        let status: SyncStatus
        let revision: UInt64
        switch await prepareToggle(enabled) {
        case .rebuildFailed:
            return .unavailableRebuildFailed
        case .superseded:
            return await currentStatus()
        case .ready(let preparedStatus, let preparedRevision):
            status = preparedStatus
            revision = preparedRevision
        }

        // Absorb anything the rebuilt store has without clobbering live edits.
        //
        // Additive: this is a *different* container, so a row's absence from it
        // says nothing about whether the user deleted it. Without the override,
        // toggling sync would wipe every entity the new store hasn't got yet.
        await persistence.rehydrate(into: store, policy: .preferRemoteAdditive)
        guard revision == toggleRevision else { return await currentStatus() }
        return status
    }
}
