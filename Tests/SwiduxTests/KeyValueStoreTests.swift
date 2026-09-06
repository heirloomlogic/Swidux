//
//  KeyValueStoreTests.swift
//  SwiduxTests
//
//  Tests for `KVKey`, `KeyValueStore`, `InMemoryKeyValueStore`,
//  `UserDefaultsKeyValueStore`, and integration with `Store`
//  (reducer dispatches → effect writes to KV store).
//

import Foundation
import Testing

@testable import Swidux

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
    fileprivate static let greeting = KVKey<String>("greeting")
}

extension KVKey where Value == Int {
    fileprivate static let answer = KVKey<Int>("answer")
}

/// Same backing-store name as `.answer` but a different value type — used to
/// verify decode-failure-returns-nil behavior.
extension KVKey where Value == String {
    fileprivate static let answerAsString = KVKey<String>("answer")
}

// MARK: - InMemoryKeyValueStore

@Suite("InMemoryKeyValueStore")
struct InMemoryKeyValueStoreTests {
    @Test("Round-trips a Codable struct")
    func roundTripStruct() {
        let store = InMemoryKeyValueStore()
        let theme = Theme(name: "dark", contrast: 80)

        store.setValue(theme, for: .theme)
        #expect(store.value(.theme) == theme)
    }

    @Test("Round-trips a Codable enum")
    func roundTripEnum() {
        let store = InMemoryKeyValueStore()
        store.setValue(SortOrder.recent, for: .sortOrder)
        #expect(store.value(.sortOrder) == .recent)
    }

    @Test("Round-trips a String payload")
    func roundTripString() {
        let store = InMemoryKeyValueStore()
        store.setValue("hello", for: .greeting)
        #expect(store.value(.greeting) == "hello")
    }

    @Test("Missing key returns nil")
    func missingKeyReturnsNil() {
        let store = InMemoryKeyValueStore()
        #expect(store.value(.greeting) == nil)
        #expect(store.contains(.greeting) == false)
    }

    @Test("setValue(nil) removes the key")
    func setNilRemoves() {
        let store = InMemoryKeyValueStore()
        store.setValue("present", for: .greeting)
        #expect(store.contains(.greeting))

        store.setValue(nil, for: .greeting)
        #expect(store.contains(.greeting) == false)
        #expect(store.value(.greeting) == nil)
    }

    @Test("removeValue removes the key")
    func removeRemoves() {
        let store = InMemoryKeyValueStore()
        store.setValue("present", for: .greeting)
        store.removeValue(for: .greeting)
        #expect(store.contains(.greeting) == false)
    }

    @Test("Decode failure on type mismatch returns nil")
    func decodeFailureReturnsNil() {
        let store = InMemoryKeyValueStore()
        store.setValue(42, for: .answer)
        #expect(store.value(.answerAsString) == nil)
        #expect(store.contains(.answer))
    }

    @Test("Concurrent writes from multiple tasks do not corrupt state")
    func concurrentWritesAreSafe() async {
        let store = InMemoryKeyValueStore()
        let count = 200

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    store.setValue(i, for: KVKey<Int>("k\(i)"))
                }
            }
        }

        let snapshot = store.snapshot()
        #expect(snapshot.count == count)
        for i in 0..<count {
            #expect(store.value(KVKey<Int>("k\(i)")) == i)
        }
    }
}

// MARK: - UserDefaultsKeyValueStore

@Suite("UserDefaultsKeyValueStore")
struct UserDefaultsKeyValueStoreTests {
    /// Returns a fresh isolated suite + a teardown closure to remove it.
    private func makeSuite() throws -> (UserDefaults, () -> Void) {
        let name = "swidux.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test("Round-trips a Codable struct")
    func roundTripStruct() throws {
        let (defaults, teardown) = try makeSuite()
        defer { teardown() }
        let store = UserDefaultsKeyValueStore(suite: defaults)

        let theme = Theme(name: "dark", contrast: 80)
        store.setValue(theme, for: .theme)
        #expect(store.value(.theme) == theme)
    }

    @Test("Missing key returns nil")
    func missingKeyReturnsNil() throws {
        let (defaults, teardown) = try makeSuite()
        defer { teardown() }
        let store = UserDefaultsKeyValueStore(suite: defaults)

        #expect(store.value(.greeting) == nil)
        #expect(store.contains(.greeting) == false)
    }

    @Test("setValue(nil) removes the key")
    func setNilRemoves() throws {
        let (defaults, teardown) = try makeSuite()
        defer { teardown() }
        let store = UserDefaultsKeyValueStore(suite: defaults)

        store.setValue("present", for: .greeting)
        #expect(store.contains(.greeting))

        store.setValue(nil, for: .greeting)
        #expect(store.contains(.greeting) == false)
    }

    @Test("removeValue removes the key")
    func removeRemoves() throws {
        let (defaults, teardown) = try makeSuite()
        defer { teardown() }
        let store = UserDefaultsKeyValueStore(suite: defaults)

        store.setValue("present", for: .greeting)
        store.removeValue(for: .greeting)
        #expect(store.contains(.greeting) == false)
    }

    @Test("Decode failure on type mismatch returns nil")
    func decodeFailureReturnsNil() throws {
        let (defaults, teardown) = try makeSuite()
        defer { teardown() }
        let store = UserDefaultsKeyValueStore(suite: defaults)

        store.setValue(42, for: .answer)
        #expect(store.value(.answerAsString) == nil)
        #expect(store.contains(.answer))
    }

    @Test("Malformed JSON written directly returns nil on decode")
    func malformedPayloadReturnsNil() throws {
        let (defaults, teardown) = try makeSuite()
        defer { teardown() }
        let store = UserDefaultsKeyValueStore(suite: defaults)

        defaults.set(Data([0xff, 0xfe, 0xfd]), forKey: "greeting")
        #expect(store.contains(.greeting))
        #expect(store.value(.greeting) == nil)
    }
}

// MARK: - Integration: reducer dispatches → effect writes to KV store

@Suite("KeyValueStore integration")
struct KeyValueStoreIntegrationTests {
    @Test("Effect writes to KV store after dispatch and value persists across rehydration")
    @MainActor
    func effectWritesToStore() async throws {
        let prefs = InMemoryKeyValueStore()

        func reducer(state: inout TestState, action: TestAction) -> Effect<TestAction>? {
            switch action {
            case .effectAction(let name):
                return Effect { @Sendable _ in
                    prefs.setValue(name, for: .greeting)
                }
            default:
                return nil
            }
        }

        let store = Store<TestState, TestAction>(
            initialState: TestState(),
            reducer: reducer
        )

        try await confirmation(expectedCount: 1) { confirm in
            store.send(.effectAction("dark"))

            for _ in 0..<50 {
                if prefs.value(.greeting) == "dark" {
                    confirm()
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        // Hydrate a fresh "session" from the same backing store.
        #expect(prefs.value(.greeting) == "dark")
    }
}
