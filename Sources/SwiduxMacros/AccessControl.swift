import SwiftSyntax

/// The access levels a struct or property can spell, narrowest first.
enum AccessLevel: Int, Comparable {
    case `private`
    case `fileprivate`
    case `internal`
    case `package`
    case `public`

    /// The level `modifiers` spell, ignoring setter-only forms such as
    /// `private(set)`, or `nil` when none is written.
    init?(_ modifiers: DeclModifierListSyntax) {
        for modifier in modifiers where modifier.detail == nil {
            switch modifier.name.tokenKind {
            case .keyword(.private): self = .private
            case .keyword(.fileprivate): self = .fileprivate
            case .keyword(.internal): self = .internal
            case .keyword(.package): self = .package
            case .keyword(.public), .keyword(.open): self = .public
            default: continue
            }
            return
        }
        return nil
    }

    /// The level a generator's struct-level access keyword names, if any.
    init?(keyword: String?) {
        switch keyword {
        case "private": self = .private
        case "fileprivate": self = .fileprivate
        case "internal": self = .internal
        case "package": self = .package
        case "public": self = .public
        default: return nil
        }
    }

    static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var keyword: String {
        switch self {
        case .private: "private"
        case .fileprivate: "fileprivate"
        case .internal: "internal"
        case .package: "package"
        case .public: "public"
        }
    }
}

/// The access prefix for a generated member mirroring a property: the struct's
/// own prefix, narrowed to the property's level when that is narrower.
///
/// Mirroring every member at the struct's level republished an internal member
/// of a `public` struct as a public, settable property of the generated class —
/// reachable from other modules through `store.observer` — and failed outright
/// when the member's type was itself internal. A `private` member becomes
/// `fileprivate`: the generated code that reads it lives in another type, in
/// the same file.
func memberAccessPrefix(structAccess: String?, member: AccessLevel?) -> String {
    let structPrefix = structAccess.map { "\($0) " } ?? ""
    // No modifier is implicitly `internal`, not "whatever the struct is".
    let member = member ?? .internal
    guard member < (AccessLevel(keyword: structAccess) ?? .internal) else { return structPrefix }
    switch member {
    case .private, .fileprivate: return "fileprivate "
    case .internal: return ""
    case .package, .public: return "\(member.keyword) "
    }
}
