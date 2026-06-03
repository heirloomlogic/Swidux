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
        await preflight.resolve(desired: mode)
    }

    /// Turns iCloud sync on or off.
    ///
    /// Flushes pending writes, rebuilds the container in the effective mode
    /// (CloudKit only when actually available, else a local fallback), swaps the
    /// active database, persists the preference, and re-hydrates via `merge`
    /// (never replace). Returns the resolved ``SyncStatus``.
    @discardableResult
    public func setSyncEnabled(_ enabled: Bool, into state: inout State) async -> SyncStatus {
        let target: SyncMode = enabled ? .iCloud : .localOnly

        // 1. Drain the debounce window so no buffered write is lost on rebuild.
        await persistence.corePlugin.flush()

        // 2. Resolve availability for the requested mode.
        let status = await preflight.resolve(desired: target)

        if status == .misconfiguredNoEntitlement {
            logger.error("iCloud sync requested but the app is not entitled; staying local-only.")
            assertionFailure("SwiduxCloudKitSync: iCloud requested but no iCloud entitlement is present.")
        }

        // 3. Use CloudKit only when it is actually usable; otherwise local.
        let effectiveMode: SyncMode = (target == .iCloud && status == .syncing) ? .iCloud : .localOnly
        rebuildDatabase(mode: effectiveMode)

        // 4. Persist the user's *choice* (not the fallback) for next launch.
        keyValue.setValue(target, for: .syncMode)
        mode = target

        // 5. Absorb anything the rebuilt store has without clobbering live edits.
        await persistence.rehydrate(into: &state)

        return enabled ? status : .localOnlyByChoice
    }

    private func rebuildDatabase(mode: SyncMode) {
        do {
            persistence.handle.db = EntityDB(modelContainer: try makeContainer(mode))
        } catch {
            logger.error(
                "Failed to rebuild \(String(describing: mode)) container: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
