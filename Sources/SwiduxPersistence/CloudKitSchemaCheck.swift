//
//  CloudKitSchemaCheck.swift
//  SwiduxPersistence
//
//  CloudKit mirroring refuses a relationship without an inverse, and a
//  `@Relation` never has one. SwiftData only finds out when the store loads —
//  as Core Data error 134060, or on some hosts as an abort — so the factory
//  checks the schema first and says what to do instead.
//

import Foundation
import SwiftData

/// A schema that CloudKit mirroring would refuse to load, found before trying.
///
/// Thrown by ``ContainerFactory/makeContainer(models:cloudKitDatabase:url:inMemory:)``
/// — and so by `CloudContainerFactory` and a sync toggle's rebuild — when a
/// CloudKit-mirrored container is requested over models declaring a
/// relationship with no inverse. A `@Relation` is always one: it is an owned
/// value composition, and a child's domain value can't hold its parent.
///
/// A local-only container over the same models is fine; only mirroring needs
/// the inverse. For a synced app, store an owned value inline with `@Inline`,
/// or register the child as an entity of its own that names its parent with a
/// `@ForeignKey`.
public struct CloudKitIncompatibleSchema: Error, LocalizedError, Sendable, Equatable {
    /// One relationship CloudKit would refuse.
    public struct Relationship: Sendable, Hashable, CustomStringConvertible {
        /// The model declaring the relationship, e.g. `"BookModel"`.
        public let entity: String

        /// The relationship's property name, e.g. `"chapters"`.
        public let name: String

        /// The related model, e.g. `"ChapterModel"`.
        public let destination: String

        /// Creates a description of one relationship.
        public init(entity: String, name: String, destination: String) {
            self.entity = entity
            self.name = name
            self.destination = destination
        }

        /// `Entity.name → Destination`.
        public var description: String { "\(entity).\(name) → \(destination)" }
    }

    /// Every relationship in the schema that has no inverse, sorted by entity
    /// and name.
    public let oneSidedRelationships: [Relationship]

    /// Creates the error for `oneSidedRelationships`.
    public init(oneSidedRelationships: [Relationship]) {
        self.oneSidedRelationships = oneSidedRelationships
    }

    /// What went wrong, which relationships, and what to use instead.
    public var errorDescription: String? {
        let names = oneSidedRelationships.map(\.description).joined(separator: ", ")
        return """
            CloudKit mirroring requires every relationship to have an inverse, and these have \
            none: \(names). A @Relation is one-sided, so a model that declares one can only be \
            stored locally. To sync it, store owned values with @Inline, or register the child \
            as its own entity and give it a @ForeignKey to its parent.
            """
    }
}

extension CloudKitIncompatibleSchema {
    /// The relationships in `schema` CloudKit mirroring would refuse, sorted by
    /// entity and name.
    static func oneSidedRelationships(in schema: Schema) -> [Relationship] {
        schema.entities
            .flatMap { entity in
                entity.relationships
                    .filter { $0.inverseName == nil && $0.inverseKeyPath == nil }
                    .map { Relationship(entity: entity.name, name: $0.name, destination: $0.destination) }
            }
            .sorted { ($0.entity, $0.name) < ($1.entity, $1.name) }
    }
}
