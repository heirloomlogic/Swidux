//
//  SyncPreflightServiceTests.swift
//  SwiduxCloudKitSyncTests
//
//  The paths that reach `SyncStatus.resolve` — the preflight closure wiring
//  and the CloudKit account-status translation — plus the local-only branch of
//  `CloudContainerFactory`. `SyncStatus.resolve` itself, and the coordinator
//  paths that consume it, are covered in SyncTests.swift.
//
//  Hermetic: no CloudKit network, no entitlement.
//

import Foundation
import SwiduxPersistence
import SwiftData
import Synchronization
import Testing

@testable import SwiduxCloudKitSync

#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - resolve(desired:) — the instance method

@Suite("SyncPreflightService.resolve")
struct SyncPreflightServiceResolveTests {
    /// One row per argument threaded through to `SyncStatus.resolve`. The
    /// resolution table itself is owned by SyncTests.swift — duplicating it
    /// here would mean two tables that have to agree.
    @Test(
        "resolve threads both probes into the resolution",
        arguments: [
            // `desired` reaches resolve.
            (SyncMode.localOnly, true, ICloudAccountState.available, SyncStatus.localOnlyByChoice),
            // The happy path.
            (.iCloud, true, .available, .syncing),
            // `isEntitled()` is threaded into `entitled`.
            (.iCloud, false, .available, .misconfiguredNoEntitlement),
            // `await accountState()` is threaded into `account`.
            (.iCloud, true, .noAccount, .unavailableNotSignedIn),
        ]
    )
    func resolveThreadsProbes(
        desired: SyncMode,
        entitled: Bool,
        account: ICloudAccountState,
        expected: SyncStatus
    ) async {
        let service = SyncPreflightService.mock(entitled: entitled, account: account)
        #expect(await service.resolve(desired: desired) == expected)
    }

    @Test("both probe closures are consulted, not a cached value")
    func probesAreCalled() async {
        // `.mock` returns constants, so drive the memberwise init directly to
        // observe that resolve reads each closure on every call.
        let entitlementCalls = Mutex(0)
        let accountCalls = Mutex(0)
        let service = SyncPreflightService(
            isEntitled: {
                entitlementCalls.withLock { $0 += 1 }
                return true
            },
            accountState: {
                accountCalls.withLock { $0 += 1 }
                return .available
            }
        )

        #expect(await service.resolve(desired: .iCloud) == .syncing)
        #expect(await service.resolve(desired: .iCloud) == .syncing)
        #expect(entitlementCalls.withLock { $0 } == 2)
        #expect(accountCalls.withLock { $0 } == 2)
    }

    /// The live account probe builds a `CKContainer`, and in a process without
    /// the iCloud entitlement that construction raises an exception or traps —
    /// it doesn't return an error. So a probe whose answer can't change the
    /// outcome must not run at all: this is what keeps an unentitled build, or
    /// a user who opted out, from ever reaching it.
    @Test("local-only consults neither probe")
    func localOnlySkipsProbes() async {
        let calls = Mutex(0)
        let service = SyncPreflightService(
            isEntitled: {
                calls.withLock { $0 += 1 }
                return true
            },
            accountState: {
                calls.withLock { $0 += 1 }
                return .available
            }
        )

        #expect(await service.resolve(desired: .localOnly) == .localOnlyByChoice)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("an unentitled build never reaches the account probe")
    func unentitledSkipsAccountProbe() async {
        let accountCalls = Mutex(0)
        let service = SyncPreflightService(
            isEntitled: { false },
            accountState: {
                accountCalls.withLock { $0 += 1 }
                return .available
            }
        )

        #expect(await service.resolve(desired: .iCloud) == .misconfiguredNoEntitlement)
        #expect(accountCalls.withLock { $0 } == 0)
    }
}

// MARK: - The entitlement check

@Suite("SyncPreflightService entitlement")
struct SyncPreflightServiceEntitlementTests {
    static let services = "com.apple.developer.icloud-services"
    static let containers = "com.apple.developer.icloud-container-identifiers"
    static let id = "iCloud.com.example.app"

    private func grants(_ entitlements: [String: Any], containerID: String? = nil) -> Bool {
        SyncPreflightService.grantsCloudKit(containerID: containerID) { entitlements[$0] }
    }

    /// The one fact the old probe got wrong. It read the ubiquity identity
    /// token — the iCloud *Drive* identity, `nil` whenever the user has iCloud
    /// Drive switched off — so a correctly built app reported itself
    /// misconfigured on those devices. The check is now a function of the
    /// entitlements alone: nothing about the user's account or settings is an
    /// input to it.
    @Test("an app entitled to CloudKit is entitled, whatever the user's iCloud Drive setting")
    func cloudKitEntitlementGrants() {
        #expect(grants([Self.services: ["CloudKit"], Self.containers: [Self.id]]))
        #expect(grants([Self.services: ["CloudKit"], Self.containers: [Self.id]], containerID: Self.id))
        // Documents alongside CloudKit changes nothing.
        #expect(grants([Self.services: ["CloudDocuments", "CloudKit"], Self.containers: [Self.id]]))
        // The wildcard a development profile may carry.
        #expect(grants([Self.services: "*", Self.containers: [Self.id]]))
    }

    @Test("a missing or partial CloudKit entitlement is not entitled")
    func partialEntitlementDoesNotGrant() {
        // No iCloud capability at all — the unsigned test host is this case.
        #expect(!grants([:]))
        // iCloud Documents only.
        #expect(!grants([Self.services: ["CloudDocuments"], Self.containers: [Self.id]]))
        // CloudKit with an empty container list: CloudKit has no default
        // container to hand out, and raises rather than failing.
        #expect(!grants([Self.services: ["CloudKit"], Self.containers: [String]()]))
        #expect(!grants([Self.services: ["CloudKit"]]))
        // A container the app asks for but isn't entitled to.
        #expect(!grants([Self.services: ["CloudKit"], Self.containers: ["iCloud.other"]], containerID: Self.id))
    }

    #if os(macOS)
    /// Reads this process's real entitlements. A `swift test` host carries no
    /// iCloud entitlement — which is exactly the process the audit crashed — so
    /// the live check must say so without constructing a `CKContainer`. Only
    /// the probe is called here, never `resolve`: if this ever regressed to
    /// `true`, `resolve(.iCloud)` would take the whole test process down.
    @Test("the live check reports an unentitled process as unentitled")
    func liveCheckReadsTheProcess() {
        #expect(!SyncPreflightService.live().isEntitled())
        #expect(!SyncPreflightService.live(containerID: Self.id).isEntitled())
    }
    #endif

    @Test("an app-supplied entitlement check replaces the built-in one")
    func appSuppliedCheckWins() {
        #expect(SyncPreflightService.live(isEntitled: { true }).isEntitled())
        #expect(!SyncPreflightService.live(isEntitled: { false }).isEntitled())
    }
}

// MARK: - CKAccountStatus translation

#if canImport(CloudKit)
@Suite("ICloudAccountState(CKAccountStatus)")
struct ICloudAccountStateTests {
    @Test(
        "each CKAccountStatus maps to its coarse state",
        arguments: [
            (CKAccountStatus.available, ICloudAccountState.available),
            (.noAccount, .noAccount),
            (.restricted, .restricted),
            (.temporarilyUnavailable, .temporarilyUnavailable),
            (.couldNotDetermine, .couldNotDetermine),
        ]
    )
    func knownStatuses(status: CKAccountStatus, expected: ICloudAccountState) {
        #expect(ICloudAccountState(status) == expected)
    }

    @Test("an unrecognised raw status degrades to couldNotDetermine")
    func unknownStatusFallsBack() throws {
        // The `@unknown default` arm: a status from a future OS must degrade to
        // unknown rather than claim availability. `#require` rather than
        // `if let` — if a future SDK stops vending unrecognised raw values this
        // should fail loudly, not pass vacuously while covering nothing.
        let future = try #require(
            CKAccountStatus(rawValue: 9999),
            "expected an unrecognised CKAccountStatus to be constructible"
        )
        #expect(ICloudAccountState(future) == .couldNotDetermine)
    }

    @Test(
        "an account-status error naming the build is a misconfiguration; any other is unknown",
        arguments: [
            (CKError.Code.missingEntitlement, ICloudAccountState.misconfigured),
            (.badContainer, .misconfigured),
            (.networkFailure, .couldNotDetermine),
            (.notAuthenticated, .couldNotDetermine),
        ]
    )
    func accountStatusErrors(code: CKError.Code, expected: ICloudAccountState) {
        #expect(ICloudAccountState(accountStatusError: CKError(code)) == expected)
    }

    @Test("a non-CloudKit account-status error is unknown")
    func foreignErrorIsUnknown() {
        #expect(ICloudAccountState(accountStatusError: CocoaError(.fileReadUnknown)) == .couldNotDetermine)
    }
}
#endif

// MARK: - CloudContainerFactory

@Suite("CloudContainerFactory")
struct CloudContainerFactoryTests {
    /// Only `.localOnly` is asserted. `.iCloud` selects `.private(id)` /
    /// `.automatic`, which wants a real iCloud entitlement to build, so
    /// exercising it would make the suite non-hermetic on CI.
    @Test("localOnly attaches no CloudKit mirror and honours the store URL")
    func localOnlyOmitsCloudKit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swidux-cloudfactory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")

        let container = try CloudContainerFactory.makeContainer(
            models: [ItemModel.self],
            mode: .localOnly,
            url: url
        )

        let configuration = try #require(container.configurations.first)
        #expect(configuration.cloudKitContainerIdentifier == nil)
        // The URL is what makes toggling sync non-destructive: both modes are
        // built at the same path, so no row ever moves.
        #expect(configuration.url == url)
    }
}
