//
//  KeyValueStore.swift
//  Swidux
//
//  Lightweight, testable key/value persistence for scalar preferences.
//  Production backend: `UserDefaultsKeyValueStore`. Test backend: `InMemoryKeyValueStore`.
//

import Foundation
import Synchronization
import os

/// A type-safe key for ``KeyValueStore``.
///
/// Declare each key once on `KVKey` so the value type travels with the name —
/// no magic strings, no per-call type parameters:
///
/// ```swift
/// extension KVKey where Value == Theme {
///     static let theme = KVKey<Theme>("theme")
/// }
///
/// extension KVKey where Value == String {
///     static let lastSeenVersion = KVKey<String>("lastSeenVersion")
/// }
/// ```
///
/// Then read and write through static-member literals:
///
/// ```swift
/// let theme = store.value(.theme) ?? .system
/// store.setValue(theme, for: .theme)
/// store.removeValue(for: .theme)
/// ```
public struct KVKey<Value: Codable>: Sendable, Hashable {
    /// The underlying name written to the backing store.
    public let name: String

    /// Creates a key with the given backing-store name.
    public init(_ name: String) {
        self.name = name
    }
}

/// A typed, Codable-only key/value store for scalar preferences.
///
/// Apps inject a `KeyValueStore` through their `Environment`, hydrate initial
/// state from it once at app start, and write to it from effects:
///
/// ```swift
/// // Environment
/// struct AppEnvironment: Sendable {
///     var keyValue: any KeyValueStore
/// }
///
/// // Hydration
/// extension AppState {
///     static func hydrated(from store: any KeyValueStore) -> AppState {
///         AppState(theme: store.value(.theme) ?? .system)
///     }
/// }
///
/// // Reducer + effect
/// case .themeChanged(let theme):
///     state.theme = theme
///     return { @Sendable _ in
///         environment.keyValue.setValue(theme, for: .theme)
///     }
/// ```
///
/// ## Hydration-only reads
///
/// Reads are intended for **hydration at app start**, not mid-cycle reads from
/// reducers. UserDefaults itself is thread-safe, but a reducer reading while an
/// effect writes creates ordering ambiguity. Reducers that need a preference
/// should read it once into state and then observe state.
///
/// ## Failures
///
/// - **Decode** (`value(_:)`): missing keys and decode failures both return
///   `nil`. Decode failures are logged via `os.Logger`.
/// - **Encode** (`setValue(_:for:)`): encode failures are logged and trigger
///   `assertionFailure` in DEBUG. Production builds log and continue. The API
///   does not throw — encoder errors are programmer mistakes (e.g. `Float.nan`),
///   and there is no useful runtime recovery from inside an effect.
///
/// ## Schema migration
///
/// `Codable` shape changes that aren't backward-compatible should declare a
/// new versioned key (e.g. `theme.v2`); this protocol does not provide
/// migration.
public protocol KeyValueStore: Sendable {
    /// Returns the decoded value, or `nil` if the key is absent or its payload
    /// fails to decode as `Value`. Decode failures are logged.
    func value<Value>(_ key: KVKey<Value>) -> Value?

    /// Stores `value`. Passing `nil` removes the key. Encode failures are
    /// logged and trigger `assertionFailure` in DEBUG.
    func setValue<Value>(_ value: Value?, for key: KVKey<Value>)

    /// Removes the value for `key`. No-op if absent.
    func removeValue<Value>(for key: KVKey<Value>)

    /// Returns `true` if the key has any stored value, regardless of decodability.
    func contains<Value>(_ key: KVKey<Value>) -> Bool
}

/// In-memory `KeyValueStore` for tests.
///
/// Reference semantics so a test can hand the same instance to `Environment`
/// and assert against it after effects run.
///
/// ```swift
/// let prefs = InMemoryKeyValueStore()
/// let env = AppEnvironment(keyValue: prefs)
/// // dispatch action that triggers an effect writing to keyValue, then:
/// #expect(prefs.value(.theme) == .dark)
/// ```
public final class InMemoryKeyValueStore: KeyValueStore {
    private let storage: Mutex<[String: Data]>
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: Logger

    /// Creates an empty store, or one prepopulated with raw payloads.
    public init(
        _ initial: [String: Data] = [:],
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        logger: Logger = Logger(subsystem: "swidux", category: "kvstore")
    ) {
        self.storage = Mutex(initial)
        self.encoder = encoder
        self.decoder = decoder
        self.logger = logger
    }

    /// Returns the decoded value, or `nil` if absent or undecodable as `Value`.
    public func value<Value>(_ key: KVKey<Value>) -> Value? {
        let data = storage.withLock { $0[key.name] }
        guard let data else { return nil }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            logger.error(
                "Decode failed for key '\(key.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Stores `value`. Passing `nil` removes the key.
    public func setValue<Value>(_ value: Value?, for key: KVKey<Value>) {
        guard let value else {
            removeValue(for: key)
            return
        }
        do {
            let data = try encoder.encode(value)
            storage.withLock { $0[key.name] = data }
        } catch {
            logger.error(
                "Encode failed for key '\(key.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            assertionFailure("Encode failed for key '\(key.name)': \(error)")
        }
    }

    /// Removes the value for `key`. No-op if absent.
    public func removeValue<Value>(for key: KVKey<Value>) {
        storage.withLock { _ = $0.removeValue(forKey: key.name) }
    }

    /// Returns `true` if the key has any stored payload.
    public func contains<Value>(_ key: KVKey<Value>) -> Bool {
        storage.withLock { $0[key.name] != nil }
    }

    /// Returns the raw payload map. Test-only affordance.
    public func snapshot() -> [String: Data] {
        storage.withLock { $0 }
    }
}
