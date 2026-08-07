//
//  KeychainKeyValueStoreTests.swift
//  SwiduxTests
//
//  Tests for `KeychainKeyValueStore`. Each test uses a unique `service`
//  string and wipes all items for that service in teardown so suites stay
//  isolated. All queries route through the data-protection keychain
//  (`kSecUseDataProtectionKeychain: true`).
//
//  ## macOS `swift test` skips the round-trip suite
//
//  The data-protection keychain requires the `keychain-access-groups`
//  entitlement, which `swift test` on macOS does not carry — the test
//  binary is unsigned. `SecItemAdd` returns `errSecMissingEntitlement`
//  (-34018) and we skip the suite. Xcode-driven test runs and iOS
//  simulator runs (the only keychain on iOS) work normally. The
//  production runtime is unaffected: real shipped apps carry the
//  required entitlements.
//
//  Two further suites cover the unentitled half of that split, so no
//  environment leaves the write path untested:
//
//  - `KeychainFailureClassificationTests` touches no keychain at all and
//    therefore runs everywhere, including macOS `swift test`.
//  - `KeychainUnentitledHostTests` is gated on the *inverse* condition, so
//    it runs exactly where -34018 fires and regression-tests the trap that
//    used to crash unsigned test hosts (#65).
//

import Foundation
import Security
import Testing

@testable import Swidux

/// Deletes every Keychain item scoped to `service`.
private func wipe(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecUseDataProtectionKeychain as String: true,
    ]
    _ = SecItemDelete(query as CFDictionary)
}

/// Probes the data-protection keychain by adding and deleting a single item.
private func isKeychainAvailable() -> Bool {
    let service = "swidux.probe.\(UUID().uuidString)"
    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "probe",
        kSecValueData as String: Data([0x00]),
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecUseDataProtectionKeychain as String: true,
    ]
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else { return false }
    wipe(service: service)
    return true
}

// MARK: - Fixtures

private struct Theme: Codable, Equatable, Sendable {
    var name: String
    var contrast: Int
}

private enum SortOrder: String, Codable, Equatable, Sendable {
    case alphabetical
    case recent
}

extension KVKey where Value == Theme {
    fileprivate static let theme = KVKey<Theme>("theme")
}

extension KVKey where Value == SortOrder {
    fileprivate static let sortOrder = KVKey<SortOrder>("sortOrder")
}

extension KVKey where Value == String {
    fileprivate static let deviceID = KVKey<String>("device-id")
}

extension KVKey where Value == Int {
    fileprivate static let counter = KVKey<Int>("counter")
}

/// Same backing-store name as `.counter` but a different value type — used to
/// verify decode-failure-returns-nil behavior.
extension KVKey where Value == String {
    fileprivate static let counterAsString = KVKey<String>("counter")
}

// MARK: - Suite

@Suite(
    "KeychainKeyValueStore",
    .enabled(
        if: isKeychainAvailable(),
        "Keychain not accessible — `swift test` on macOS lacks the keychain entitlement. Run in Xcode or on iOS simulator."
    )
)
struct KeychainKeyValueStoreTests {
    /// Returns a store backed by a unique `service` plus a teardown closure
    /// that wipes every item in that service.
    private func makeStore() -> (KeychainKeyValueStore, () -> Void) {
        let service = "swidux.tests.\(UUID().uuidString)"
        return (KeychainKeyValueStore(service: service), { wipe(service: service) })
    }

    @Test("Round-trips a Codable struct")
    func roundTripStruct() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        let theme = Theme(name: "dark", contrast: 80)
        store.setValue(theme, for: .theme)
        #expect(store.value(.theme) == theme)
    }

    @Test("Round-trips a Codable enum")
    func roundTripEnum() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        store.setValue(SortOrder.recent, for: .sortOrder)
        #expect(store.value(.sortOrder) == .recent)
    }

    @Test("Round-trips a String payload")
    func roundTripString() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        let id = UUID().uuidString
        store.setValue(id, for: .deviceID)
        #expect(store.value(.deviceID) == id)
    }

    @Test("Missing key returns nil")
    func missingKeyReturnsNil() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        #expect(store.value(.deviceID) == nil)
        #expect(store.contains(.deviceID) == false)
    }

    @Test("setValue(nil) removes the key")
    func setNilRemoves() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        store.setValue("present", for: .deviceID)
        #expect(store.contains(.deviceID))

        store.setValue(nil, for: .deviceID)
        #expect(store.contains(.deviceID) == false)
        #expect(store.value(.deviceID) == nil)
    }

    @Test("removeValue removes the key")
    func removeRemoves() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        store.setValue("present", for: .deviceID)
        store.removeValue(for: .deviceID)
        #expect(store.contains(.deviceID) == false)
    }

    @Test("removeValue on a missing key is a no-op")
    func removeMissingIsNoOp() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        store.removeValue(for: .deviceID)
        #expect(store.contains(.deviceID) == false)
    }

    @Test("Decode failure on type mismatch returns nil")
    func decodeFailureReturnsNil() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        store.setValue(42, for: .counter)
        #expect(store.value(.counterAsString) == nil)
        #expect(store.contains(.counter))
    }

    @Test("setValue twice updates the existing item")
    func updateOverwrites() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        store.setValue("first", for: .deviceID)
        store.setValue("second", for: .deviceID)
        #expect(store.value(.deviceID) == "second")
    }

    @Test("Items in different services do not collide")
    func servicesAreIsolated() {
        let (storeA, teardownA) = makeStore()
        let (storeB, teardownB) = makeStore()
        defer {
            teardownA()
            teardownB()
        }

        storeA.setValue("a-value", for: .deviceID)
        storeB.setValue("b-value", for: .deviceID)

        #expect(storeA.value(.deviceID) == "a-value")
        #expect(storeB.value(.deviceID) == "b-value")
    }

    @Test("Value survives across store instances with the same service")
    func valueSurvivesAcrossInstances() {
        let service = "swidux.tests.\(UUID().uuidString)"
        defer { wipe(service: service) }

        let writer = KeychainKeyValueStore(service: service)
        let id = UUID().uuidString
        writer.setValue(id, for: .deviceID)

        let reader = KeychainKeyValueStore(service: service)
        #expect(reader.value(.deviceID) == id)
    }

    @Test("Device-ID hydration pattern: read-or-mint round-trips")
    func deviceIDHydrationPattern() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        let firstLaunchID =
            store.value(.deviceID)
            ?? {
                let new = UUID().uuidString
                store.setValue(new, for: .deviceID)
                return new
            }()

        let secondLaunchID =
            store.value(.deviceID)
            ?? {
                let new = UUID().uuidString
                store.setValue(new, for: .deviceID)
                return new
            }()

        #expect(firstLaunchID == secondLaunchID)
    }

    @Test("Successful writes and removals report true")
    func successfulMutationsReportTrue() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        #expect(store.setValue("present", for: .deviceID))
        #expect(store.setValue("updated", for: .deviceID))
        #expect(store.removeValue(for: .deviceID))
    }

    @Test("Removing an absent key reports true — the key is absent either way")
    func removingAbsentKeyReportsTrue() {
        let (store, teardown) = makeStore()
        defer { teardown() }

        #expect(store.removeValue(for: .deviceID))
        #expect(store.setValue(nil, for: .deviceID))
    }
}

// MARK: - Failure classification

/// Pure table-driven coverage of ``KeychainKeyValueStore/failureKind(for:)``.
///
/// Touches no keychain, so unlike the round-trip suite above this runs in every
/// environment — including the unsigned macOS `swift test` that CI uses.
@Suite("KeychainKeyValueStore failure classification")
struct KeychainFailureClassificationTests {
    /// Statuses determined by signing, device lock, or keychain availability.
    /// The caller cannot fix these by writing better code, so they must not trap.
    @Test(
        "Environment-determined statuses are not programmer errors",
        arguments: [
            errSecMissingEntitlement,
            errSecInteractionNotAllowed,
            errSecNotAvailable,
        ] as [OSStatus]
    )
    func environmentStatuses(status: OSStatus) {
        #expect(KeychainKeyValueStore.failureKind(for: status) == .environment)
    }

    /// Everything else stays a programmer error, so a malformed query still
    /// trips `assertionFailure` in DEBUG rather than being silently swallowed.
    @Test(
        "Malformed-query and unknown statuses stay programmer errors",
        arguments: [
            errSecParam,
            errSecAllocate,
            errSecBadReq,
            errSecDuplicateItem,
            errSecItemNotFound,
            errSecDecode,
            OSStatus(-99_999),
        ] as [OSStatus]
    )
    func programmerErrorStatuses(status: OSStatus) {
        #expect(KeychainKeyValueStore.failureKind(for: status) == .programmerError)
    }
}

// MARK: - Unentitled host

/// Regression coverage for #65, gated on the *inverse* of the round-trip
/// suite's condition: it runs only where the keychain is unavailable, which is
/// precisely where the old `assertionFailure` crashed the test host before the
/// bundle could attach. On this repo's CI that is every macOS `swift test` run.
@Suite(
    "KeychainKeyValueStore on an unentitled host",
    .enabled(
        if: !isKeychainAvailable(),
        "Keychain is available here — this suite covers the unentitled path only."
    )
)
struct KeychainUnentitledHostTests {
    private func makeStore() -> KeychainKeyValueStore {
        KeychainKeyValueStore(service: "swidux.tests.\(UUID().uuidString)")
    }

    @Test("setValue degrades instead of trapping, and reports the failure")
    func setValueDegrades() {
        #expect(makeStore().setValue("value", for: .deviceID) == false)
    }

    @Test("A failed write leaves the key absent rather than half-written")
    func failedWriteLeavesKeyAbsent() {
        let store = makeStore()
        _ = store.setValue("value", for: .deviceID)

        #expect(store.value(.deviceID) == nil)
        #expect(store.contains(.deviceID) == false)
    }

    @Test("deviceIdentity returns a usable identity instead of crashing")
    func deviceIdentityDegrades() {
        // The adopter scenario from #65: an app minting a device identity at
        // launch used to trap here, taking its own XCTest host down with it.
        let identity = makeStore().deviceIdentity()

        #expect(UUID(uuidString: identity) != nil)
    }

    @Test("removeValue on an unentitled host is still a no-op, not a trap")
    func removeValueDegrades() {
        // Asserted on the observable contract rather than the returned Bool:
        // whether the delete reports `errSecItemNotFound` or the entitlement
        // error is environment detail. Reaching the expectation at all is the
        // proof that matters — the old code trapped before getting here.
        let store = makeStore()
        _ = store.removeValue(for: .deviceID)

        #expect(store.contains(.deviceID) == false)
    }
}
