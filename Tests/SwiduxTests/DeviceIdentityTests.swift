//
//  DeviceIdentityTests.swift
//  SwiduxTests
//
//  Tests for `KeyValueStore.deviceIdentity()` — read-or-mint of a stable
//  per-install identity.
//

import Foundation
import Testing

@testable import Swidux

@Suite("KeyValueStore.deviceIdentity")
struct DeviceIdentityTests {
    @Test("mints and persists a UUID on first call")
    func mintsOnFirstCall() {
        let store = InMemoryKeyValueStore()
        #expect(store.value(.deviceID) == nil)

        let id = store.deviceIdentity()

        #expect(UUID(uuidString: id) != nil)
        #expect(store.value(.deviceID) == id)
    }

    @Test("returns the same identity on subsequent calls")
    func stableAcrossCalls() {
        let store = InMemoryKeyValueStore()
        let first = store.deviceIdentity()
        let second = store.deviceIdentity()
        #expect(first == second)
    }

    @Test("a store that already holds an identity returns it unchanged")
    func survivesAcrossStoreInstances() {
        // Simulates relaunch/reinstall against the same backing store: a new
        // store wrapper over the same persisted payloads recalls the identity.
        let backing = InMemoryKeyValueStore()
        let original = backing.deviceIdentity()

        let relaunched = InMemoryKeyValueStore(backing.snapshot())
        #expect(relaunched.deviceIdentity() == original)
    }

    @Test("honors a custom key")
    func customKey() {
        let store = InMemoryKeyValueStore()
        let custom = KVKey<String>("my.device.id")
        let id = store.deviceIdentity(key: custom)
        #expect(store.value(custom) == id)
        #expect(store.value(.deviceID) == nil)
    }

    @Test("the persisted value is authoritative when a concurrent racer wins")
    func persistedValueIsAuthoritative() {
        // Simulates losing a first-mint race: this caller's write is
        // overwritten by a racer's before the re-read. The returned identity
        // must be the persisted (winning) one, not the local mint.
        let store = RacingKeyValueStore(winner: "racer-id")
        let id = store.deviceIdentity()
        #expect(id == "racer-id")
    }

    @Test("a store that cannot persist still yields a usable identity")
    func unpersistableStoreStillMints() {
        // The #65 scenario, at the level `deviceIdentity` sees it: an unsigned
        // or unentitled Keychain accepts no writes, and the caller still needs
        // an identity for the session rather than a crash.
        let store = UnpersistableKeyValueStore()

        #expect(UUID(uuidString: store.deviceIdentity()) != nil)
    }

    @Test("a failed write skips the read-back it can only lose")
    func failedWriteSkipsReadBack() {
        let store = UnpersistableKeyValueStore()

        _ = store.deviceIdentity()

        // One read for the initial lookup and no second one: re-reading a store
        // that just refused the write can only return the same nil.
        #expect(store.readCount == 1)
    }
}

/// A store whose reads return a fixed winner once anything has been written —
/// as if a concurrent first-caller's write landed after ours.
private final class RacingKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let winner: String
    private var hasWritten = false

    init(winner: String) {
        self.winner = winner
    }

    func value<Value>(_ key: KVKey<Value>) -> Value? {
        hasWritten ? winner as? Value : nil
    }

    @discardableResult
    func setValue<Value>(_ value: Value?, for key: KVKey<Value>) -> Bool {
        hasWritten = true
        return true
    }

    @discardableResult
    func removeValue<Value>(for key: KVKey<Value>) -> Bool {
        hasWritten = false
        return true
    }

    func contains<Value>(_ key: KVKey<Value>) -> Bool {
        hasWritten
    }
}

/// A store that accepts nothing and reports it — an unentitled Keychain, in
/// miniature. Counts reads so a test can prove the read-back is skipped.
private final class UnpersistableKeyValueStore: KeyValueStore, @unchecked Sendable {
    private(set) var readCount = 0

    func value<Value>(_ key: KVKey<Value>) -> Value? {
        readCount += 1
        return nil
    }

    @discardableResult
    func setValue<Value>(_ value: Value?, for key: KVKey<Value>) -> Bool { false }

    @discardableResult
    func removeValue<Value>(for key: KVKey<Value>) -> Bool { false }

    func contains<Value>(_ key: KVKey<Value>) -> Bool { false }
}
