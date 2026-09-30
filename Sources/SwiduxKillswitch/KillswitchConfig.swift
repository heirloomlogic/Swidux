//
//  KillswitchConfig.swift
//  SwiduxKillswitch
//
//  Decoded shape of the remote killswitch JSON.
//

import Foundation

/// The remote killswitch configuration fetched from the server.
///
/// Version fields are parsed strictly and must be full `major.minor.patch`
/// SemVer — `"2.0"` is rejected. Only the *app's own* version is parsed
/// leniently at evaluation time (see `SemanticVersion.init(tolerant:)`),
/// because `CFBundleShortVersionString` may carry fewer components.
public struct KillswitchConfig: Codable, Sendable, Equatable {
    /// Versions below this SemVer string are blocked.
    public var minimumSupportedVersion: String?
    /// Exact version strings to block.
    public var blockedVersions: [String]?
    /// Half-open ranges (`"a.b.c..<x.y.z"`) to block.
    public var blockedRanges: [String]?
    /// Override for the blocker's title string.
    public var blockedTitle: String?
    /// Override for the blocker's body copy.
    public var blockedMessage: String?
    /// URL presented as an "Update" action on the blocker.
    public var updateURL: String?

    /// Creates a config; all fields default to `nil`.
    public init(
        minimumSupportedVersion: String? = nil,
        blockedVersions: [String]? = nil,
        blockedRanges: [String]? = nil,
        blockedTitle: String? = nil,
        blockedMessage: String? = nil,
        updateURL: String? = nil
    ) {
        self.minimumSupportedVersion = minimumSupportedVersion
        self.blockedVersions = blockedVersions
        self.blockedRanges = blockedRanges
        self.blockedTitle = blockedTitle
        self.blockedMessage = blockedMessage
        self.updateURL = updateURL
    }

    /// The top-level keys in `data` that this type doesn't declare, sorted.
    ///
    /// Decoding ignores them, so a misspelled `minimumSupportedVerison`
    /// decodes as a config with no minimum. The live service logs each one in
    /// debug builds; internal so a test can assert what is reported. Empty
    /// when `data` isn't a JSON object.
    static func unknownKeys(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        // The synthesized coding keys are the stored property names.
        let known = Set(Mirror(reflecting: KillswitchConfig()).children.compactMap(\.label))
        return object.keys.filter { !known.contains($0) }.sorted()
    }

    /// Every version rule that fails strict parsing, as `field "value"`.
    ///
    /// Such a rule never matches, so it fails open. Evaluation logs each one;
    /// internal so a test can assert what is reported without scraping the
    /// unified log.
    var malformedRules: [String] {
        let minimum = minimumSupportedVersion.map { [$0] } ?? []
        return minimum.filter { SemanticVersion($0) == nil }.map { #"minimumSupportedVersion "\#($0)""# }
            + (blockedVersions ?? []).filter { SemanticVersion($0) == nil }.map { #"blockedVersions "\#($0)""# }
            + (blockedRanges ?? []).filter { VersionRange($0) == nil }.map { #"blockedRanges "\#($0)""# }
    }
}
