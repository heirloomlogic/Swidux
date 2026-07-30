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
            // `ubiquityTokenAvailable()` is threaded into `entitled`.
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
        let service = SyncPreflightService.mock(ubiquityToken: entitled, account: account)
        #expect(await service.resolve(desired: desired) == expected)
    }

    @Test("both probe closures are consulted, not a cached value")
    func probesAreCalled() async {
        // `.mock` returns constants, so drive the memberwise init directly to
        // observe that resolve reads each closure on every call.
        let tokenCalls = Mutex(0)
        let accountCalls = Mutex(0)
        let service = SyncPreflightService(
            ubiquityTokenAvailable: {
                tokenCalls.withLock { $0 += 1 }
                return true
            },
            accountState: {
                accountCalls.withLock { $0 += 1 }
                return .available
            }
        )

        #expect(await service.resolve(desired: .iCloud) == .syncing)
        #expect(await service.resolve(desired: .iCloud) == .syncing)
        #expect(tokenCalls.withLock { $0 } == 2)
        #expect(accountCalls.withLock { $0 } == 2)
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
