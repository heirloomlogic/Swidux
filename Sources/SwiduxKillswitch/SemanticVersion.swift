//
//  SemanticVersion.swift
//  SwiduxKillswitch
//
//  SemVer parser with full precedence comparison.
//

import Foundation

/// A parsed semantic version conforming to the SemVer 2.0.0 spec.
public struct SemanticVersion: Sendable, Hashable, Comparable {
    /// Major version number.
    public let major: Int
    /// Minor version number.
    public let minor: Int
    /// Patch version number.
    public let patch: Int
    /// Prerelease identifiers; empty for stable releases.
    public let prerelease: [PrereleaseIdentifier]

    /// Creates a version from its components.
    public init(
        major: Int,
        minor: Int,
        patch: Int,
        prerelease: [PrereleaseIdentifier] = []
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses a SemVer string such as `"1.2.3"`, `"1.2.3-beta.1"`,
    /// or `"1.2.3-beta.1+build42"`. Returns `nil` on malformed input.
    public init?(_ string: String) {
        guard !string.isEmpty else { return nil }

        // Strip build metadata (everything after '+')
        let versionString: String
        if let plusIndex = string.firstIndex(of: "+") {
            versionString = String(string[string.startIndex..<plusIndex])
        } else {
            versionString = string
        }

        // Split prerelease from version core
        let coreAndPrerelease = versionString.split(separator: "-", maxSplits: 1)
        guard !coreAndPrerelease.isEmpty else { return nil }
        let coreString = String(coreAndPrerelease[0])

        // Parse major.minor.patch
        let parts = coreString.split(separator: ".")
        guard parts.count == 3,
            let major = Int(parts[0]),
            let minor = Int(parts[1]),
            let patch = Int(parts[2]),
            major >= 0, minor >= 0, patch >= 0
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch

        // Parse prerelease identifiers
        if coreAndPrerelease.count == 2 {
            let prereleaseString = String(coreAndPrerelease[1])
            let identifiers = prereleaseString.split(separator: ".").map(String.init)
            guard !identifiers.isEmpty else { return nil }

            var parsed: [PrereleaseIdentifier] = []
            for id in identifiers {
                guard !id.isEmpty else { return nil }
                if let numeric = Int(id) {
                    parsed.append(.numeric(numeric))
                } else {
                    parsed.append(.alphanumeric(id))
                }
            }
            self.prerelease = parsed
        } else {
            self.prerelease = []
        }
    }

    /// SemVer 2.0.0 precedence comparison.
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        // 1. Compare major.minor.patch numerically
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // 2. A version with prerelease has lower precedence than the
        //    same version without prerelease.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false  // equal
        case (true, false): return false  // release > prerelease
        case (false, true): return true  // prerelease < release
        case (false, false): break
        }

        // 3. Compare prerelease identifiers left-to-right.
        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for i in 0..<count where lhs.prerelease[i] != rhs.prerelease[i] {
            return lhs.prerelease[i] < rhs.prerelease[i]
        }

        // 4. Fewer identifiers = lower precedence when all preceding match.
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// A single prerelease identifier, either numeric or alphanumeric.
    public enum PrereleaseIdentifier: Sendable, Hashable, Comparable {
        case numeric(Int)
        case alphanumeric(String)

        /// Numeric identifiers sort before alphanumeric; within a kind, natural ordering.
        public static func < (lhs: PrereleaseIdentifier, rhs: PrereleaseIdentifier) -> Bool {
            switch (lhs, rhs) {
            case (.numeric(let l), .numeric(let r)):
                return l < r
            case (.numeric, .alphanumeric):
                // Numeric identifiers always have lower precedence
                return true
            case (.alphanumeric, .numeric):
                return false
            case (.alphanumeric(let l), .alphanumeric(let r)):
                return l < r
            }
        }
    }
}
