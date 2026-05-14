//
//  KeychainKeyValueStoreTests.swift
//  SwiduxTests
//
//  Tests for `KeychainKeyValueStore`. Each test uses a unique `service`
//  string and wipes all items for that service in teardown so suites stay
//  isolated. All queries route through the data-protection keychain
//  (`kSecUseDataProtectionKeychain: true`).
//
//  ## macOS `swift test` skips this suite
//
//  The data-protection keychain requires the `keychain-access-groups`
//  entitlement, which `swift test` on macOS does not carry — the test
//  binary is unsigned. `SecItemAdd` returns `errSecMissingEntitlement`
//  (-34018) and we skip the suite. Xcode-driven test runs and iOS
//  simulator runs (the only keychain on iOS) work normally. The
//  production runtime is unaffected: real shipped apps carry the
//  required entitlements.
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
}
