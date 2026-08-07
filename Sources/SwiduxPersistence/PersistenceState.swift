//
//  PersistenceState.swift
//  SwiduxPersistence
//
//  Optional state slice an app can embed to drive a launch hydration gate and
//  (when `SwiduxCloudKitSync` is linked) a sync settings toggle.
//

import Foundation
import Swidux

/// State slice describing hydration progress and the current sync posture.
///
/// Embed as `@Slice var persistence: PersistenceState` on `AppState` if you
/// want to gate the UI on first-load hydration or render a sync toggle.
@Swidux
public nonisolated struct PersistenceState: Sendable, Equatable {
    /// First-load hydration progress.
    public enum HydrationPhase: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// First-load hydration progress for the launch gate.
    ///
    /// Spelled out as `PersistenceState.HydrationPhase` because the generated
    /// observer is a peer at file scope, where the bare nested name won't resolve.
    public var hydrationPhase: PersistenceState.HydrationPhase = .loading
    /// What the user asked for (persisted across launches).
    public var syncMode: SyncMode = .localOnly
    /// The resolved runtime reality. The app updates this from the
    /// `SyncCoordinator` (e.g. the status returned by `setSyncEnabled`).
    public var syncStatus: SyncStatus = .localOnlyByChoice

    /// Creates a persistence state slice.
    public init(
        hydrationPhase: HydrationPhase = .loading,
        syncMode: SyncMode = .localOnly,
        syncStatus: SyncStatus = .localOnlyByChoice
    ) {
        self.hydrationPhase = hydrationPhase
        self.syncMode = syncMode
        self.syncStatus = syncStatus
    }
}
