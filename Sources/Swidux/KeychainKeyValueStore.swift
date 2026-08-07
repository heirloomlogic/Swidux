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
/// ## Sandboxing & entitlements (macOS)
///
/// This store uses the data-protection keychain
/// (`kSecUseDataProtectionKeychain`), so it **never** triggers a user-facing
/// prompt: no legacy "Always Allow / Deny" dialog, no prompt on a locked
/// keychain, and — because no `kSecAttrAccessControl` is requested — no
/// Touch ID / Face ID / password challenge.
///
/// A *sandboxed* macOS app must still be entitled to use that keychain. It
/// needs either an `application-identifier` entitlement (Xcode adds this
/// automatically for provisioning-profile–signed builds) or an explicit
/// `keychain-access-groups` entry. Without one, ``setValue(_:for:)`` returns
/// `false` and logs `errSecMissingEntitlement` (`OSStatus` −34018). This is a
/// build/signing condition surfaced at runtime, **not** a user prompt:
///
/// ```xml
/// <key>keychain-access-groups</key>
/// <array>
///     <string>$(AppIdentifierPrefix)com.example.myapp</string>
/// </array>
/// ```
///
/// iOS / iPadOS / tvOS / watchOS only have the data-protection keychain and
/// supply the access group implicitly — no extra entitlement is required.
///
/// ### Which entitlement, for privacy
///
/// Encryption, this-device-only accessibility, iCloud-sync exclusion, and
/// backup exclusion are identical whichever path you take — the access group
/// only governs *which of your own apps* can read an item, never third
/// parties or the cloud. For app-private identifiers, in order of strictness:
///
/// 1. **Most private:** a provisioning-profile–signed build with
///    `accessGroup: nil`, relying on the implicit `application-identifier`
///    group (`<TeamPrefix>.<bundle-id>`). No other app — even one you sign
///    under the same team — can ever be entitled to it. Mirrors the iOS
///    default exactly; zero sharing surface.
/// 2. **Practically equivalent:** a `keychain-access-groups` array whose
///    *only* entry is the team-prefixed bundle id (the snippet above). Use
///    this when a profile-signed build isn't available (unsigned local / CI
///    dev, where −34018 bites). The one delta from (1): another app you sign
///    under the same team could also declare that string and read the items.
/// 3. **Intentional sharing only:** a deliberately shared group string. The
///    *first* element of `keychain-access-groups` becomes the default group
///    for new items, so never put a shared group first for private data.
///
/// ## Sendable
///
/// Marked `@unchecked Sendable`. The `Security` framework's `SecItem*` calls
/// are thread-safe; the struct's stored properties are all themselves
/// `Sendable` or treated so. Matches the pattern of ``UserDefaultsKeyValueStore``.
///
/// ## When the keychain isn't reachable
///
/// Writes report their outcome instead of trapping. `errSecMissingEntitlement`,
/// `errSecInteractionNotAllowed`, and `errSecNotAvailable` are properties of the
/// environment — an unsigned build, a locked device, a keychain that isn't there
/// — so they are logged, and ``setValue(_:for:)`` returns `false`. Statuses that
/// indicate a malformed query still trip `assertionFailure` in DEBUG.
///
/// This matters most under `CODE_SIGNING_ALLOWED=NO`, where the binary carries
/// no entitlements at all: the advice above cannot apply, because there is
/// nothing to attach an entitlement to. Test hosts build that way, so a store
/// that trapped would take the test process down with it.
///
/// Check the result where a fallback exists:
///
/// ```swift
/// if !kv.setValue(token, for: .authToken) {
///     // Keychain unreachable — hold it in memory for this session only.
/// }
/// ```
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
    ///     `nil` (default) uses the app's private keychain. Either way, a
    ///     sandboxed macOS app needs a keychain entitlement — see
    ///     *Sandboxing & entitlements (macOS)* in the type overview.
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
    /// where the value is minted once and rarely changes.
    ///
    /// Failures are always logged. Encode failures and malformed-query statuses
    /// also trigger `assertionFailure` in DEBUG; environment-determined statuses
    /// do not — see *When the keychain isn't reachable* in the type overview.
    ///
    /// - Returns: `true` if the value is now stored (or removed, for `nil`).
    @discardableResult
    public func setValue<Value>(_ value: Value?, for key: KVKey<Value>) -> Bool {
        guard let value else { return removeValue(for: key) }
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            report("Encode failed", key: key.name, error: error)
            return false
        }

        let query = baseQuery(account: key.name)
        let valueAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.rawValue,
        ]

        let addStatus = SecItemAdd(query.merging(valueAttributes) { $1 } as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(query as CFDictionary, valueAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                report("Keychain update failed", key: key.name, status: updateStatus)
                return false
            }
            return true
        default:
            report("Keychain add failed", key: key.name, status: addStatus)
            return false
        }
    }

    /// Removes the value for `key`. `errSecItemNotFound` is a no-op; other
    /// failures are logged.
    ///
    /// - Returns: `true` if the key is now absent — which `errSecItemNotFound`
    ///   satisfies, since the caller asked for absence and got it.
    ///
    /// Unlike ``setValue(_:for:)`` this path never traps, on any status. It has
    /// always been log-only, and a delete that fails leaves the store in the
    /// state it was already in.
    @discardableResult
    public func removeValue<Value>(for key: KVKey<Value>) -> Bool {
        let query = baseQuery(account: key.name)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        logger.error(
            "Keychain delete failed for key '\(key.name, privacy: .public)': OSStatus \(status)"
        )
        return false
    }

    /// Returns `true` if a Keychain item exists for `key`, regardless of
    /// decodability.
    public func contains<Value>(_ key: KVKey<Value>) -> Bool {
        var query = baseQuery(account: key.name)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Why a Keychain call failed, which decides whether the failure is worth
    /// trapping on in DEBUG.
    enum FailureKind: Equatable, Sendable {
        /// Determined by the environment — signing, device lock, or keychain
        /// availability. No amount of correct code prevents these, so they are
        /// logged and reported to the caller rather than trapped on.
        case environment
        /// A malformed query or an un-encodable value: a bug in the caller,
        /// worth surfacing loudly during development.
        case programmerError
    }

    /// Classifies a non-success `OSStatus`.
    ///
    /// The environment set is deliberately narrow — anything not known to be
    /// environmental stays a programmer error, so a genuinely malformed query
    /// is never silently swallowed. Add to the list only with a concrete case.
    static func failureKind(for status: OSStatus) -> FailureKind {
        switch status {
        // -34018: no keychain entitlement. A sandboxed macOS app without a
        // provisioning profile, and every `CODE_SIGNING_ALLOWED=NO` build —
        // where no entitlement can be embedded, so there is nothing to fix.
        case errSecMissingEntitlement,
            // -25308: keychain locked and non-interactive.
            errSecInteractionNotAllowed,
            // -25291: no keychain available at all.
            errSecNotAvailable:
            return .environment
        default:
            return .programmerError
        }
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
        if Self.failureKind(for: status) == .programmerError {
            assertionFailure("\(message) for key '\(key)': OSStatus \(status)")
        }
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
