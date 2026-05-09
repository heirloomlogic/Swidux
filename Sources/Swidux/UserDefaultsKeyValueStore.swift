//
//  UserDefaultsKeyValueStore.swift
//  Swidux
//
//  Production `KeyValueStore` backed by `UserDefaults`.
//  Every value is JSON-encoded as `Data`.
//

import Foundation
import os

/// A `KeyValueStore` backed by a `UserDefaults` suite.
///
/// All values are JSON-encoded as `Data` and read back through `Codable`.
/// This means `@AppStorage` cannot observe values written here — by design.
/// Swidux state is the source of truth; `@AppStorage` would be a parallel
/// observation channel that drifts.
///
/// ```swift
/// let prefs = UserDefaultsKeyValueStore()                       // .standard
/// let prefs = UserDefaultsKeyValueStore(suite: .init(suiteName: "group.app")!)
/// ```
///
/// ## Sendable
///
/// Marked `@unchecked Sendable` because `UserDefaults` is documented
/// thread-safe but its `Sendable` conformance in Foundation is declared
/// `@available(*, unavailable)` — the type checker does not propagate it,
/// so any holder must opt in explicitly. Reads and writes against
/// `UserDefaults` are safe to perform from any actor.
public struct UserDefaultsKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: Logger

    /// Creates a store backed by the given `UserDefaults` suite.
    public init(
        suite: UserDefaults = .standard,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        logger: Logger = Logger(subsystem: "swidux", category: "kvstore")
    ) {
        self.defaults = suite
        self.encoder = encoder
        self.decoder = decoder
        self.logger = logger
    }

    /// Returns the decoded value, or `nil` if absent or undecodable as `Value`.
    /// Decode failures are logged.
    public func value<Value>(_ key: KVKey<Value>) -> Value? {
        guard let data = defaults.data(forKey: key.name) else { return nil }
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
            defaults.set(data, forKey: key.name)
        } catch {
            logger.error(
                "Encode failed for key '\(key.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            assertionFailure("Encode failed for key '\(key.name)': \(error)")
        }
    }

    /// Removes the value for `key`. No-op if absent.
    public func removeValue<Value>(for key: KVKey<Value>) {
        defaults.removeObject(forKey: key.name)
    }

    /// Returns `true` if the key has any stored value.
    public func contains<Value>(_ key: KVKey<Value>) -> Bool {
        defaults.object(forKey: key.name) != nil
    }
}
