//
//  PersistenceMacros.swift
//  SwiduxPersistence
//
//  Public macro declarations for the persistence layer. Implementations live
//  in the `SwiduxMacros` compiler-plugin target.
//

/// Delete rule for an `@Relation`. Mirrors SwiftData's
/// `Schema.Relationship.DeleteRule` case names so the generated
/// `@Relationship(deleteRule:)` resolves in the model's SwiftData context.
public enum SwiduxDeleteRule: Sendable {
    case noAction
    case nullify
    case cascade
    case deny
}

/// Generates a SwiftData `@Model` shadow class for a domain entity struct and
/// conforms it to ``PersistableEntity`` (and the shadow to ``PersistableModel``).
///
/// Apply to a value-type domain entity that already conforms to
/// `Identifiable & Equatable & Sendable` with `ID == UUID`. By default every
/// stored property is mirrored onto the model (SwiftData persists scalars and
/// `Codable` composites natively); use the marker macros to override:
/// ``Relation(deleteRule:inverse:)``, ``ForeignKey()``, ``Inline()``, ``Ignored()``.
@attached(peer, names: suffixed(Model))
@attached(extension, conformances: PersistableEntity, names: arbitrary)
public macro Persisted() = #externalMacro(module: "SwiduxMacros", type: "PersistedMacro")

/// Marks a property as a SwiftData relationship to another `@Persisted` entity.
/// The property's type must reference the related *domain* type (`[Card]`,
/// `Card?`, or `Card`); the generated model substitutes the `…Model` shadow.
/// `inverse` is supplied as a key path on the generated model type, e.g.
/// `\CardModel.deck`.
@attached(peer)
public macro Relation(deleteRule: SwiduxDeleteRule, inverse: AnyKeyPath? = nil) =
    #externalMacro(module: "SwiduxMacros", type: "MarkerMacro")

/// Marks a `UUID` property as a scalar parent reference. Intent/documentation
/// marker; the property is mirrored as an ordinary scalar column.
@attached(peer)
public macro ForeignKey() = #externalMacro(module: "SwiduxMacros", type: "MarkerMacro")

/// Forces a `Codable` property into a single opaque JSON `Data` column instead
/// of letting SwiftData expand it. Useful for keeping a CloudKit record compact
/// or sidestepping SwiftData `Codable`-attribute edge cases.
@attached(peer)
public macro Inline() = #externalMacro(module: "SwiduxMacros", type: "MarkerMacro")

/// Excludes a derived/denormalized property from the generated model. The
/// property must be optional so it can be reconstructed as `nil` on load.
@attached(peer)
public macro Ignored() = #externalMacro(module: "SwiduxMacros", type: "MarkerMacro")
