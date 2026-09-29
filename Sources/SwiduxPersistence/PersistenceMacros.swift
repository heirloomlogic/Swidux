//
//  PersistenceMacros.swift
//  SwiduxPersistence
//
//  Public macro declarations for the persistence layer. Implementations live
//  in the `SwiduxMacros` compiler-plugin target.
//

// A macro expansion resolves names against the imports of the file it expands
// in, and `@Persisted` expands to `@Model`, `FetchDescriptor` and `#Predicate`.
// Re-exporting SwiftData makes `import SwiduxPersistence` — all the how-to
// shows — enough; without it that file gets a wall of "unknown attribute
// 'Model'" errors reported against generated code. This module's public API
// already exposes SwiftData types (`ModelContainer`, `PersistentModel`), so a
// client can't use it without SwiftData in the first place.
@_exported import SwiftData

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
/// ``Relation(deleteRule:)``, ``ForeignKey()``, ``Inline()``, ``Ignored()``,
/// ``BelongsTo(_:inverse:)``, and ``HasMany(_:inverse:)``.
@attached(peer, names: suffixed(Model))
@attached(extension, conformances: PersistableEntity, names: arbitrary)
public macro Persisted() = #externalMacro(module: "SwiduxMacros", type: "PersistedMacro")

/// Marks a property as a SwiftData relationship to another `@Persisted` entity.
/// The property's type must reference the related *domain* type (`[Card]` or
/// `Card?`); the generated model substitutes the `…Model` shadow.
///
/// The current implementation embeds child values in the parent and reconciles
/// them when the parent is saved. Its converters do not support back-references
/// or bidirectional relationships. Give the child a ``ForeignKey()`` `UUID` if
/// it needs to name its parent; this marker adds no referential constraint.
/// For independently addressable entities, use ``BelongsTo(_:inverse:)`` and
/// ``HasMany(_:inverse:)`` to generate storage references from scalar IDs.
///
/// That also makes the relationship **local-only**. CloudKit mirroring requires
/// an inverse on every relationship, so a model that declares a `@Relation`
/// can't be synced: ``ContainerFactory`` refuses to build a mirrored container
/// over it and throws ``CloudKitIncompatibleSchema``. In a synced app, store an
/// owned value with ``Inline()``, or register the child as an entity of its own
/// with a ``ForeignKey()`` to its parent.
///
/// A to-many relation is **unordered**: SwiftData stores it as a set, so the
/// array comes back from storage in no particular order, and a change that only
/// reorders it is not saved. Sort in the domain (or store an explicit position)
/// when order matters.
@attached(peer)
public macro Relation(deleteRule: SwiduxDeleteRule) =
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

/// Declares a child-owned association using an optional scalar parent ID.
/// The inverse names the parent's `@HasMany` ID-array property. The generated
/// SwiftData reference is optional and uses a nullify delete rule; ownership
/// and deletion policies are enforced by the registered `EntityAssociation`.
@attached(peer)
public macro BelongsTo<Destination>(_ destination: Destination.Type, inverse: String) =
    #externalMacro(module: "SwiduxMacros", type: "MarkerMacro")

/// Declares the inverse of a child's `@BelongsTo` property. The `[UUID]` domain
/// property stores ordering metadata; the child's parent ID determines membership.
/// Supply an empty-array default to keep the scalar column CloudKit-compatible.
@attached(peer)
public macro HasMany<Destination>(_ destination: Destination.Type, inverse: String) =
    #externalMacro(module: "SwiduxMacros", type: "MarkerMacro")
