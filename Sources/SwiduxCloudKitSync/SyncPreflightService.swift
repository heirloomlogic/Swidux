//
//  SyncPreflightService.swift
//  SwiduxCloudKitSync
//
//  Detects whether iCloud sync is actually usable at launch, and resolves the
//  desired mode + availability into a `SyncStatus`. Struct-of-closures with
//  `.live` / `.mock` factories, mirroring `KillswitchService`.
//

import Foundation
import SwiduxPersistence

#if canImport(CloudKit)
import CloudKit
#endif

/// Coarse iCloud account state, decoupled from CloudKit's `CKAccountStatus`.
public enum ICloudAccountState: Sendable, Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
}

/// Probes iCloud availability. Inject `.mock(...)` in tests.
public struct SyncPreflightService: Sendable {
    /// Whether an iCloud ubiquity token is present — a proxy for "entitled and
    /// an account is configured". `nil` token usually means not-entitled or
    /// not-signed-in.
    public var ubiquityTokenAvailable: @Sendable () -> Bool
    /// The CloudKit account status.
    public var accountState: @Sendable () async -> ICloudAccountState

    /// Creates a preflight service from the two probe closures.
    public init(
        ubiquityTokenAvailable: @escaping @Sendable () -> Bool,
        accountState: @escaping @Sendable () async -> ICloudAccountState
    ) {
        self.ubiquityTokenAvailable = ubiquityTokenAvailable
        self.accountState = accountState
    }

    /// Resolves the live `SyncStatus` for the desired mode.
    public func resolve(desired: SyncMode) async -> SyncStatus {
        SyncStatus.resolve(
            desired: desired,
            entitled: ubiquityTokenAvailable(),
            account: await accountState()
        )
    }

    /// Live probe backed by `FileManager` + `CKContainer`.
    public static func live(containerID: String? = nil) -> SyncPreflightService {
        SyncPreflightService(
            ubiquityTokenAvailable: {
                FileManager.default.ubiquityIdentityToken != nil
            },
            accountState: {
                #if canImport(CloudKit)
                let container = containerID.map { CKContainer(identifier: $0) } ?? CKContainer.default()
                do {
                    return mapAccountStatus(try await container.accountStatus())
                } catch {
                    // A container that can't answer is unknown, not absent —
                    // the caller degrades to not-signed-in either way.
                    return .couldNotDetermine
                }
                #else
                return .couldNotDetermine
                #endif
            }
        )
    }

    #if canImport(CloudKit)
    /// Maps CloudKit's account status onto the coarse ``ICloudAccountState``.
    ///
    /// Split out of ``live(containerID:)`` so the mapping — including the
    /// `@unknown default` — is reachable from tests without a real
    /// `CKContainer`. Internal: it is a seam, not API.
    static func mapAccountStatus(_ status: CKAccountStatus) -> ICloudAccountState {
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine: return .couldNotDetermine
        @unknown default: return .couldNotDetermine
        }
    }
    #endif

    /// Deterministic stub for tests.
    public static func mock(ubiquityToken: Bool, account: ICloudAccountState) -> SyncPreflightService {
        SyncPreflightService(
            ubiquityTokenAvailable: { ubiquityToken },
            accountState: { account }
        )
    }
}

extension SyncStatus {
    /// Pure resolution of desired mode + availability into a status.
    ///
    /// - `localOnly` ⇒ `.localOnlyByChoice`.
    /// - `iCloud` but not entitled ⇒ `.misconfiguredNoEntitlement` (a build bug).
    /// - `iCloud`, entitled, account `.available` ⇒ `.syncing`.
    /// - `iCloud`, entitled, account otherwise ⇒ not-signed-in / restricted.
    public static func resolve(desired: SyncMode, entitled: Bool, account: ICloudAccountState) -> SyncStatus {
        switch desired {
        case .localOnly:
            return .localOnlyByChoice
        case .iCloud:
            guard entitled else { return .misconfiguredNoEntitlement }
            switch account {
            case .available:
                return .syncing
            case .restricted:
                return .unavailableRestricted
            case .noAccount, .temporarilyUnavailable, .couldNotDetermine:
                return .unavailableNotSignedIn
            }
        }
    }
}
