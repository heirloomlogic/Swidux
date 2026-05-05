//
//  VersionRange.swift
//  SwiduxKillswitch
//
//  Half-open range of semantic versions.
//

import Foundation

/// A half-open range `[lowerBound, upperBound)` of semantic versions.
public struct VersionRange: Sendable, Hashable {
    /// Inclusive lower bound.
    public let lowerBound: SemanticVersion
    /// Exclusive upper bound.
    public let upperBound: SemanticVersion

    /// Creates a range. Fails if `lowerBound >= upperBound`.
    public init?(lowerBound: SemanticVersion, upperBound: SemanticVersion) {
        guard lowerBound < upperBound else { return nil }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Parses a string in `"a.b.c..<x.y.z"` format.
    public init?(_ string: String) {
        let separator = "..<"
        guard let range = string.range(of: separator) else { return nil }

        let lowerString = String(string[string.startIndex..<range.lowerBound])
        let upperString = String(string[range.upperBound..<string.endIndex])

        guard let lower = SemanticVersion(lowerString),
            let upper = SemanticVersion(upperString)
        else { return nil }

        self.init(lowerBound: lower, upperBound: upper)
    }

    /// Returns `true` if `version` is within `[lowerBound, upperBound)`.
    public func contains(_ version: SemanticVersion) -> Bool {
        version >= lowerBound && version < upperBound
    }
}
