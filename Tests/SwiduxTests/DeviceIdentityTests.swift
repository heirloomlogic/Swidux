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
}
