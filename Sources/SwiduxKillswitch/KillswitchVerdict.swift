//
//  KillswitchVerdict.swift
//  SwiduxKillswitch
//
//  Verdict produced by evaluating a killswitch config.
//

import Foundation
import os

/// Logs killswitch evaluation diagnostics.
private let logger = Logger(subsystem: "swidux", category: "killswitch")

/// The result of evaluating the current app version against a killswitch
/// configuration. Fail-open: unparseable data yields `.allowed`.
public enum KillswitchVerdict: Sendable, Equatable {
    case unknown
    case allowed
    case blocked(title: String?, message: String?, updateURL: URL?)

    /// Evaluates the given config against `currentVersionString`.
    ///
    /// The current version is parsed leniently
    /// (``SemanticVersion/init(tolerant:)``) because
    /// `CFBundleShortVersionString` may carry one to three components —
    /// marketing versions like `"2.0"` must still evaluate. Config-side
    /// versions are parsed strictly and must be full `major.minor.patch`.
    ///
    /// Fail-open policy: if the current version string cannot be parsed even
    /// leniently, or if the config contains no matching rules, the verdict is
    /// `.allowed`. The unparseable case logs an error — it means the
    /// killswitch is silently inert for this install.
    public static func evaluate(
        _ config: KillswitchConfig,
        against currentVersionString: String
    ) -> KillswitchVerdict {
        guard let currentVersion = SemanticVersion(tolerant: currentVersionString) else {
            logger.error(
                """
                Unparseable app version '\(currentVersionString, privacy: .public)' — \
                killswitch fails open, verdict .allowed.
                """
            )
            return .allowed
        }

        // Check minimum supported version
        if let minString = config.minimumSupportedVersion,
            let minVersion = SemanticVersion(minString),
            currentVersion < minVersion
        {
            return .blocked(
                title: config.blockedTitle,
                message: config.blockedMessage,
                updateURL: config.updateURL.flatMap(URL.init(string:))
            )
        }

        // Check explicitly blocked versions
        if let blockedVersions = config.blockedVersions {
            for versionString in blockedVersions {
                if let blocked = SemanticVersion(versionString),
                    currentVersion == blocked
                {
                    return .blocked(
                        title: config.blockedTitle,
                        message: config.blockedMessage,
                        updateURL: config.updateURL.flatMap(URL.init(string:))
                    )
                }
            }
        }

        // Check blocked ranges
        if let blockedRanges = config.blockedRanges {
            for rangeString in blockedRanges {
                if let range = VersionRange(rangeString),
                    range.contains(currentVersion)
                {
                    return .blocked(
                        title: config.blockedTitle,
                        message: config.blockedMessage,
                        updateURL: config.updateURL.flatMap(URL.init(string:))
                    )
                }
            }
        }

        return .allowed
    }

    /// `true` when the verdict is `.blocked`.
    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    /// The blocked verdict's update URL, but only when its scheme is safe to
    /// open. The URL comes from remote config, so only schemes that lead to
    /// an update (web or App Store) are honored — never arbitrary ones.
    public var openableUpdateURL: URL? {
        guard case .blocked(_, _, let url) = self,
            let url,
            let scheme = url.scheme,
            ["https", "itms-apps", "macappstore"].contains(scheme)
        else { return nil }
        return url
    }
}
