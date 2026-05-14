//
//  KeychainKeyValueStore.swift
//  Swidux
//
//  `KeyValueStore` backed by the system Keychain.
//  Every value is JSON-encoded as `Data` and stored as a generic password
//  item keyed by `(service, account)` where `account = key.name`.
//

import Foundation
import Security
import os

/// A `KeyValueStore` backed by the system Keychain.
///
/// Values are JSON-encoded as `Data` and stored as `kSecClassGenericPassword`
/// items keyed by `(service, account)` where `service` is supplied at init
/// and `account` is ``KVKey/name``.
///
/// The primary use case is anonymous device identity that should survive app
/// reinstall — a UUID that lets analytics correlate sessions for an app that
/// has no user account system. Hydrate once at launch into `AppState`,
/// feed `AnalyticsIdentity(userID: \.deviceID, …)`, and never read the
/// Keychain again at steady state.
///
/// ```swift
/// extension KVKey where Value == String {
///     static let deviceID = KVKey<String>("device-id")
/// }
///
/// let kv = KeychainKeyValueStore(service: "com.example.myapp")
/// let deviceID = kv.value(.deviceID) ?? {
///     let new = UUID().uuidString
///     kv.setValue(new, for: .deviceID)
///     return new
/// }()
/// ```
///
/// ## Accessibility
///
/// The default ``Accessibility/afterFirstUnlockThisDeviceOnly`` is tuned for
/// device-bound identifiers: items stay accessible in the background after
/// first unlock but are excluded from iCloud Keychain sync and device-to-device
/// migration. Choose a stricter level (``Accessibility/whenUnlockedThisDeviceOnly``,
/// ``Accessibility/whenPasscodeSetThisDeviceOnly``) for sensitive material;
/// the protocol's `Codable` surface is fine for short opaque tokens but not
/// designed for secrets that require Face ID / Touch ID gating.
///
/// ## Sendable
///
/// Marked `@unchecked Sendable`. The `Security` framework's `SecItem*` calls
/// are thread-safe; the struct's stored properties are all themselves
/// `Sendable` or treated so. Matches the pattern of ``UserDefaultsKeyValueStore``.
public struct KeychainKeyValueStore: KeyValueStore, @unchecked Sendable {
    /// Controls when stored items are readable. See Apple's
    /// `kSecAttrAccessible` documentation for the full semantics.
    public enum Accessibility: Sendable {
        /// Accessible after first unlock. Migrates with a device backup and
        /// can sync via iCloud Keychain if the app enables it.
        case afterFirstUnlock
        /// Accessible after first unlock. **This device only** — excluded
        /// from iCloud Keychain and device-to-device migration. Default.
        case afterFirstUnlockThisDeviceOnly
        /// Accessible only while the device is unlocked. iCloud-syncable.
        case whenUnlocked
        /// Accessible only while the device is unlocked. This device only.
        case whenUnlockedThisDeviceOnly
        /// Requires a passcode to be set on the device; deleted if the
        /// passcode is removed. Strictest level commonly used.
        case whenPasscodeSetThisDeviceOnly

        fileprivate var rawValue: CFString {
            switch self {
            case .afterFirstUnlock:
                return kSecAttrAccessibleAfterFirstUnlock
            case .afterFirstUnlockThisDeviceOnly:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenUnlocked:
                return kSecAttrAccessibleWhenUnlocked
            case .whenUnlockedThisDeviceOnly:
                return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .whenPasscodeSetThisDeviceOnly:
                return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
            }
        }
    }

    private let service: String
    private let accessGroup: String?
    private let accessibility: Accessibility
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: Logger

    /// Creates a Keychain-backed store.
    ///
    /// - Parameters:
    ///   - service: The `kSecAttrService` value used to scope this store's
    ///     items. Typically the app's bundle identifier or a stable
    ///     reverse-DNS string.
    ///   - accessGroup: Optional `kSecAttrAccessGroup`. Set to share items
    ///     across apps or extensions in the same Keychain access group.
    ///     Requires the `keychain-access-groups` entitlement to be
    ///     configured. `nil` (default) uses the app's private keychain.
    ///   - accessibility: When items become readable. See ``Accessibility``.
    ///   - encoder: JSON encoder used to serialize values.
    ///   - decoder: JSON decoder used to deserialize values.
    ///   - logger: `os.Logger` used for failure logging.
    public init(
        service: String,
        accessGroup: String? = nil,
        accessibility: Accessibility = .afterFirstUnlockThisDeviceOnly,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        logger: Logger = Logger(subsystem: "swidux", category: "kvstore")
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility
        self.encoder = encoder
        self.decoder = decoder
        self.logger = logger
    }

    /// Returns the decoded value, or `nil` if absent or undecodable as `Value`.
    /// Both missing keys (`errSecItemNotFound`) and decode failures return
    /// `nil`; only decode failures and unexpected Keychain errors are logged.
    public func value<Value>(_ key: KVKey<Value>) -> Value? {
        var query = baseQuery(account: key.name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            do {
                return try decoder.decode(Value.self, from: data)
            } catch {
                logger.error(
                    "Decode failed for key '\(key.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        case errSecItemNotFound:
            return nil
        default:
            logger.error(
                "Keychain read failed for key '\(key.name, privacy: .public)': OSStatus \(status)"
            )
            return nil
        }
    }

    /// Stores `value`. Passing `nil` removes the key.
    ///
    /// Tries `SecItemAdd` first; on `errSecDuplicateItem` falls back to
    /// `SecItemUpdate`. This favors the first-write path (1 syscall) over
    /// the rewrite path (2 syscalls), which matches the device-ID use case
    /// where the value is minted once and rarely changes. Encode failures
    /// and unexpected Keychain errors are logged and trigger
    /// `assertionFailure` in DEBUG.
    public func setValue<Value>(_ value: Value?, for key: KVKey<Value>) {
        guard let value else {
            removeValue(for: key)
            return
        }
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            report("Encode failed", key: key.name, error: error)
            return
        }

        let query = baseQuery(account: key.name)
        let valueAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.rawValue,
        ]

        let addStatus = SecItemAdd(query.merging(valueAttributes) { $1 } as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(query as CFDictionary, valueAttributes as CFDictionary)
            if updateStatus != errSecSuccess {
                report("Keychain update failed", key: key.name, status: updateStatus)
            }
        default:
            report("Keychain add failed", key: key.name, status: addStatus)
        }
    }

    /// Removes the value for `key`. `errSecItemNotFound` is a no-op; other
    /// failures are logged.
    public func removeValue<Value>(for key: KVKey<Value>) {
        let query = baseQuery(account: key.name)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error(
                "Keychain delete failed for key '\(key.name, privacy: .public)': OSStatus \(status)"
            )
        }
    }

    /// Returns `true` if a Keychain item exists for `key`, regardless of
    /// decodability.
    public func contains<Value>(_ key: KVKey<Value>) -> Bool {
        var query = baseQuery(account: key.name)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func report(_ message: String, key: String, error: Error) {
        logger.error(
            "\(message, privacy: .public) for key '\(key, privacy: .public)': \(error.localizedDescription, privacy: .public)"
        )
        assertionFailure("\(message) for key '\(key)': \(error)")
    }

    private func report(_ message: String, key: String, status: OSStatus) {
        logger.error(
            "\(message, privacy: .public) for key '\(key, privacy: .public)': OSStatus \(status)"
        )
        assertionFailure("\(message) for key '\(key)': OSStatus \(status)")
    }

    // `kSecClassGenericPassword`: app-local KV data. (`InternetPassword` carries
    // server/protocol/port attributes for network credentials.)
    //
    // `kSecUseDataProtectionKeychain`: opts macOS into the modern iOS-style
    // keychain, which keys items by `(service, account)` with no auth prompts.
    // On iOS / iPadOS / tvOS / watchOS it's the only keychain.
    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }
}
