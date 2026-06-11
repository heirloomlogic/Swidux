//
//  SyncStatus.swift
//  SwiduxPersistence
//
//  Shared sync-mode + status vocabulary. Pure value types with no CloudKit
//  dependency — `SwiduxCloudKitSync` resolves real availability into these.
//

/// Whether persistence is on-device only or synced via iCloud.
public enum SyncMode: String, Codable, Sendable, Equatable {
    /// All data stays on this device; never touches iCloud.
    case localOnly
    /// Data syncs via the user's private CloudKit database when usable.
    case iCloud
}

/// The resolved runtime sync reality, surfaced to app UI. Mirrors the
/// verdict-in-state pattern used by `KillswitchVerdict`.
public enum SyncStatus: Sendable, Equatable {
    /// The user opted out; running on-device only. Not an error.
    case localOnlyByChoice
    /// Entitled, signed in, and actively syncing.
    case syncing
    /// Entitled but no iCloud account is signed in (user-recoverable).
    case unavailableNotSignedIn
    /// iCloud is unavailable due to a device restriction (MDM/parental).
    case unavailableRestricted
    /// Sync was requested but the app is not entitled — a build/signing bug.
    case misconfiguredNoEntitlement
    /// The container rebuild for the requested mode failed; the previous
    /// database stays active and the user's choice was **not** persisted.
    case unavailableRebuildFailed

    /// Whether the app is running in a non-syncing or impaired state.
    public var isDegraded: Bool {
        switch self {
        case .syncing, .localOnlyByChoice:
            return false
        case .unavailableNotSignedIn, .unavailableRestricted, .misconfiguredNoEntitlement,
            .unavailableRebuildFailed:
            return true
        }
    }

    /// Whether the user can fix this by signing into iCloud.
    public var isUserActionable: Bool {
        self == .unavailableNotSignedIn
    }
}
