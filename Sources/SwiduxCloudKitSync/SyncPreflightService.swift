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

#if os(macOS)
import Security
#endif

/// Coarse iCloud account state, decoupled from CloudKit's `CKAccountStatus`.
public enum ICloudAccountState: Sendable, Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
    /// CloudKit rejected this build's entitlements or container
    /// (`CKError.missingEntitlement` / `.badContainer`) — a build or
    /// provisioning bug, not something the user can fix.
    case misconfigured
}

#if canImport(CloudKit)
extension ICloudAccountState {
    /// Translates CloudKit's `CKAccountStatus` into this coarser vocabulary.
    ///
    /// A status this build doesn't recognise degrades to ``couldNotDetermine``
    /// rather than claiming availability — an unknown account is treated as
    /// unusable, never as usable.
    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .couldNotDetermine
        @unknown default: self = .couldNotDetermine
        }
    }

    /// Translates an error from `CKContainer.accountStatus()`.
    ///
    /// Only the two errors that name the build itself are ``misconfigured``;
    /// anything else — a network failure, a busy daemon — is unknown, which the
    /// caller degrades to not-signed-in.
    init(accountStatusError error: any Error) {
        switch (error as? CKError)?.code {
        case .missingEntitlement, .badContainer: self = .misconfigured
        default: self = .couldNotDetermine
        }
    }
}
#endif

/// Probes iCloud availability. Inject `.mock(...)` in tests.
public struct SyncPreflightService: Sendable {
    /// Whether this process carries the CloudKit entitlement.
    ///
    /// Answer `false` only when that is certain. A `false` is reported as a
    /// build bug and keeps the toggle local-only; a `true` is what lets
    /// ``accountState`` run at all — and the live account probe builds a
    /// `CKContainer`, which raises an exception or traps in an unentitled
    /// process rather than returning an error.
    public var isEntitled: @Sendable () -> Bool
    /// The CloudKit account status.
    public var accountState: @Sendable () async -> ICloudAccountState

    /// Creates a preflight service from the two probe closures.
    public init(
        isEntitled: @escaping @Sendable () -> Bool,
        accountState: @escaping @Sendable () async -> ICloudAccountState
    ) {
        self.isEntitled = isEntitled
        self.accountState = accountState
    }

    /// Creates a preflight service whose entitlement probe was named for the
    /// ubiquity identity token.
    ///
    /// That token is the iCloud Drive identity, not an entitlement check: it is
    /// `nil` for a correctly entitled app whose user has iCloud Drive switched
    /// off. Pass a real entitlement check as `isEntitled`.
    @available(*, deprecated, renamed: "init(isEntitled:accountState:)")
    public init(
        ubiquityTokenAvailable: @escaping @Sendable () -> Bool,
        accountState: @escaping @Sendable () async -> ICloudAccountState
    ) {
        self.init(isEntitled: ubiquityTokenAvailable, accountState: accountState)
    }

    /// The entitlement probe, under the name it had when it read the ubiquity
    /// identity token.
    @available(*, deprecated, renamed: "isEntitled")
    public var ubiquityTokenAvailable: @Sendable () -> Bool {
        get { isEntitled }
        set { isEntitled = newValue }
    }

    /// Resolves the live `SyncStatus` for the desired mode.
    ///
    /// Consults a probe only when its answer can change the result: not at all
    /// for `.localOnly`, and not the account for a build that isn't entitled.
    /// That is a safety property, not an optimisation — the live account probe
    /// builds a `CKContainer`, which raises an exception or traps in a process
    /// without the iCloud entitlement rather than returning an error.
    public func resolve(desired: SyncMode) async -> SyncStatus {
        guard desired == .iCloud else { return .localOnlyByChoice }
        guard isEntitled() else { return .misconfiguredNoEntitlement }
        return SyncStatus.resolve(desired: desired, entitled: true, account: await accountState())
    }

    /// Live probe backed by the process's entitlements and `CKContainer`.
    ///
    /// On macOS the entitlement check is definitive. It reads this process's
    /// own code-signing entitlements, and requires `CloudKit` among
    /// `com.apple.developer.icloud-services` and a
    /// `com.apple.developer.icloud-container-identifiers` list that is
    /// non-empty and, when `containerID` is given, names it.
    ///
    /// iOS, tvOS, watchOS, and visionOS offer no public API for a process to
    /// read its own entitlements, so there the build is trusted unless you pass
    /// `isEntitled`. That trust is narrower than it sounds: those platforms
    /// refuse to launch a binary claiming entitlements its profile doesn't
    /// grant, so a running build lacks CloudKit only if its entitlements file
    /// never asked for it — a fact fixed at build time, which surfaces on the
    /// first `.iCloud` probe in development. A build that is entitled but
    /// pointed at the wrong container is still caught, from the
    /// `CKError.badContainer` or `.missingEntitlement` the account probe gets.
    ///
    /// - Parameters:
    ///   - containerID: The CloudKit container to probe, or `nil` for the
    ///     default container. Pass the id you build the container with.
    ///   - isEntitled: Your own entitlement check, replacing the built-in one —
    ///     for instance a flag set by the build configuration that sets
    ///     `CODE_SIGN_ENTITLEMENTS`.
    /// - Returns: A preflight service that probes this process and account.
    public static func live(
        containerID: String? = nil,
        isEntitled: (@Sendable () -> Bool)? = nil
    ) -> SyncPreflightService {
        SyncPreflightService(
            isEntitled: isEntitled ?? { processIsEntitledToCloudKit(containerID: containerID) },
            accountState: {
                #if canImport(CloudKit)
                let container = containerID.map { CKContainer(identifier: $0) } ?? CKContainer.default()
                do {
                    return ICloudAccountState(try await container.accountStatus())
                } catch {
                    return ICloudAccountState(accountStatusError: error)
                }
                #else
                return .couldNotDetermine
                #endif
            }
        )
    }

    /// Deterministic stub for tests.
    public static func mock(entitled: Bool, account: ICloudAccountState) -> SyncPreflightService {
        SyncPreflightService(
            isEntitled: { entitled },
            accountState: { account }
        )
    }

    /// Deterministic stub for tests, under the entitlement probe's former name.
    @available(*, deprecated, renamed: "mock(entitled:account:)")
    public static func mock(ubiquityToken: Bool, account: ICloudAccountState) -> SyncPreflightService {
        mock(entitled: ubiquityToken, account: account)
    }

    /// Whether this process's own entitlements grant CloudKit, where they can
    /// be read at all.
    static func processIsEntitledToCloudKit(containerID: String?) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return grantsCloudKit(containerID: containerID) { name in
            SecTaskCopyValueForEntitlement(task, name as CFString, nil)
        }
        #else
        // Unreadable here; `live(containerID:isEntitled:)` says why trusting
        // the build holds.
        return true
        #endif
    }

    /// Whether a set of entitlements lets this process reach `containerID`, or
    /// the default container, through CloudKit.
    ///
    /// The default container needs a non-empty identifier list too. CloudKit
    /// finds the default container through that list, and with nothing there
    /// `CKContainer.default()` raises ("containerIdentifier can not be nil")
    /// rather than failing.
    static func grantsCloudKit(containerID: String?, entitlement: (String) -> Any?) -> Bool {
        let services = entitlement("com.apple.developer.icloud-services")
        let servesCloudKit =
            (services as? [String]).map { $0.contains("CloudKit") || $0.contains("*") }
            ?? (services as? String == "*")
        guard servesCloudKit else { return false }
        let containers = entitlement("com.apple.developer.icloud-container-identifiers") as? [String] ?? []
        guard let containerID else { return !containers.isEmpty }
        return containers.contains(containerID)
    }
}

extension SyncStatus {
    /// Pure resolution of desired mode + availability into a status.
    ///
    /// - `localOnly` ⇒ `.localOnlyByChoice`.
    /// - `iCloud` but not entitled, or CloudKit rejects the build's
    ///   entitlements ⇒ `.misconfiguredNoEntitlement` (a build bug).
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
            case .misconfigured:
                return .misconfiguredNoEntitlement
            }
        }
    }
}
