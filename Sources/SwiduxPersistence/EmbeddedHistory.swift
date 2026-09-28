//
//  EmbeddedHistory.swift
//  SwiduxPersistence
//
//  Traces a change to a `@Relation` child — a row of a model no registration
//  mirrors, whose value lives inside its parent's — back to the registered row
//  that embeds it, so the tick can read that one row instead of every table.
//

import Foundation
import SwiftData

/// The `@Relation` structure below the registered models: which models they
/// embed, at any depth, and how to find the rows holding a given child.
///
/// Built from the container's schema, following only relationships declared on
/// a model as a key path to another ``PersistableModel`` — the shape `@Relation`
/// generates. A relationship to a model the app manages by hand is not an
/// embedding, because no domain value contains that model's rows.
struct EmbeddedRelations {
    /// One relationship from a model that holds children to its children's
    /// model.
    struct Edge {
        /// `Schema.entityName` of the model holding the relationship.
        let parentEntity: String

        /// The rows of the parent model holding any child whose `id` is in the
        /// set, as their persistent identifiers and identities.
        let parents: (ModelContext, [UUID]) throws -> [(pid: PersistentIdentifier, id: UUID)]
    }

    /// Every embedded model's type, by entity name.
    private(set) var modelTypes: [String: any PersistableModel.Type] = [:]

    /// The relationships holding each embedded model's rows, by its entity name.
    private(set) var edgesInto: [String: [Edge]] = [:]

    /// The registered entities that reach each embedded model, by its name.
    private(set) var registeredAncestors: [String: Set<String>] = [:]

    /// Every embedded model's entity name.
    var names: Dictionary<String, any PersistableModel.Type>.Keys { modelTypes.keys }

    /// Walks the relationships below `registered` in `schema`.
    init(registered: [String: any PersistableModel.Type], schema: Schema) {
        var frontier = registered.map { (name: $0.key, type: $0.value, ancestor: $0.key) }
        var seen = Set(registered.keys)
        while let next = frontier.popLast() {
            guard let entity = schema.entitiesByName[next.name] else { continue }
            for relationship in entity.relationships {
                guard let keyPath = relationship.keypath,
                    let edge = Self.edge(from: next.type, entityName: next.name, keyPath: keyPath)
                else { continue }
                let child = relationship.destination
                // A registered child is read directly by its own reader.
                guard registered[child] == nil else { continue }
                edgesInto[child, default: []].append(edge.edge)
                registeredAncestors[child, default: []].insert(next.ancestor)
                modelTypes[child] = edge.childType
                if seen.insert(child).inserted {
                    frontier.append((child, edge.childType, next.ancestor))
                }
            }
        }
        // An ancestor reaches everything below what it reaches.
        var changed = true
        while changed {
            changed = false
            for (child, edges) in edgesInto {
                for edge in edges {
                    guard let above = registeredAncestors[edge.parentEntity] else { continue }
                    let before = registeredAncestors[child]?.count ?? 0
                    registeredAncestors[child, default: []].formUnion(above)
                    if registeredAncestors[child]?.count != before { changed = true }
                }
            }
        }
    }

    /// The edge a relationship key path describes, when it is a to-many or
    /// to-one relationship to a ``PersistableModel``.
    ///
    /// The key path comes from the schema and its value type is only known at
    /// run time, so both ends are opened here: `P` from the parent's metatype,
    /// `C` from the key path's value type.
    private static func edge<P: PersistableModel>(
        from parent: P.Type, entityName: String, keyPath: AnyKeyPath
    ) -> (edge: Edge, childType: any PersistableModel.Type)? {
        guard let optional = type(of: keyPath).valueType as? any SwiduxOptionalRelation.Type else {
            return nil
        }
        let wrapped = optional.wrappedRelationType
        if let array = wrapped as? any SwiduxModelArray.Type {
            return toMany(P.self, array.elementModel, entityName: entityName, keyPath: keyPath)
        }
        if let model = wrapped as? any PersistableModel.Type {
            return toOne(P.self, model, entityName: entityName, keyPath: keyPath)
        }
        return nil
    }

    private static func toMany<P: PersistableModel, C: PersistableModel>(
        _ parent: P.Type, _ child: C.Type, entityName: String, keyPath: AnyKeyPath
    ) -> (edge: Edge, childType: any PersistableModel.Type)? {
        guard let typed = keyPath as? KeyPath<P, [C]?> else { return nil }
        let relationship = sendable(typed)
        let edge = Edge(parentEntity: entityName) { context, ids in
            try parents(in: context, of: C.self, ids: ids) { matches in
                Predicate<P> { parent in
                    PredicateExpressions.build_NilCoalesce(
                        lhs: PredicateExpressions.build_flatMap(
                            PredicateExpressions.build_KeyPath(root: parent, keyPath: relationship)
                        ) { children in
                            PredicateExpressions.build_contains(children) { child in
                                PredicateExpressions.build_evaluate(PredicateExpressions.build_Arg(matches), child)
                            }
                        },
                        rhs: PredicateExpressions.build_Arg(false))
                }
            }
        }
        return (edge, C.self)
    }

    private static func toOne<P: PersistableModel, C: PersistableModel>(
        _ parent: P.Type, _ child: C.Type, entityName: String, keyPath: AnyKeyPath
    ) -> (edge: Edge, childType: any PersistableModel.Type)? {
        guard let typed = keyPath as? KeyPath<P, C?> else { return nil }
        let relationship = sendable(typed)
        let edge = Edge(parentEntity: entityName) { context, ids in
            try parents(in: context, of: C.self, ids: ids) { matches in
                Predicate<P> { parent in
                    PredicateExpressions.build_NilCoalesce(
                        lhs: PredicateExpressions.build_flatMap(
                            PredicateExpressions.build_KeyPath(root: parent, keyPath: relationship)
                        ) { child in
                            PredicateExpressions.build_evaluate(PredicateExpressions.build_Arg(matches), child)
                        },
                        rhs: PredicateExpressions.build_Arg(false))
                }
            }
        }
        return (edge, C.self)
    }

    /// Fetches the parents holding any child in `ids`, a chunk at a time.
    ///
    /// The child side of the predicate is the child model's generated
    /// `swiduxBatchFetchDescriptor(ids:)` predicate, composed in with
    /// `evaluate`, rather than a match on `persistentModelID` or on `\.id`
    /// written here. Measured: an identifier match inside a to-many subquery
    /// returns the wrong parents, and `\C.id` in this generic context is the
    /// protocol witness, not the stored attribute — the same trap as
    /// `tombstone[\.id]`.
    private static func parents<P: PersistableModel, C: PersistableModel>(
        in context: ModelContext,
        of child: C.Type,
        ids: [UUID],
        predicate: (Predicate<C>) -> Predicate<P>
    ) throws -> [(pid: PersistentIdentifier, id: UUID)] {
        var found: [(pid: PersistentIdentifier, id: UUID)] = []
        for chunk in EntityDB.chunks(ids) {
            guard let matches = C.swiduxBatchFetchDescriptor(ids: chunk).predicate else { continue }
            for row in try context.fetch(FetchDescriptor<P>(predicate: predicate(matches))) {
                found.append((row.persistentModelID, row.id))
            }
        }
        return found
    }

    /// A key path read off the schema is as immutable as any other, but the
    /// predicate builders want it statically `Sendable`, which a runtime cast
    /// cannot express.
    private static func sendable<Root, Value>(
        _ keyPath: KeyPath<Root, Value>
    ) -> KeyPath<Root, Value> & Sendable {
        unsafeBitCast(keyPath, to: (KeyPath<Root, Value> & Sendable).self)
    }
}

/// Opens an optional relationship's wrapped type.
protocol SwiduxOptionalRelation {
    static var wrappedRelationType: Any.Type { get }
}

extension Optional: SwiduxOptionalRelation {
    static var wrappedRelationType: Any.Type { Wrapped.self }
}

/// Opens a to-many relationship's element model.
protocol SwiduxModelArray {
    static var elementModel: any PersistableModel.Type { get }
}

extension Array: SwiduxModelArray where Element: PersistableModel {
    static var elementModel: any PersistableModel.Type { Element.self }
}

// MARK: - Resolving a window's embedded changes

extension EntityDB {
    /// The registered rows embedding the children in `changed`, by the
    /// registered entity that owns them.
    ///
    /// Each child's identity is read by its persistent identifier, then its
    /// holders are found one relationship up, repeatedly, until the rows found
    /// are registered ones. A child no longer on disk was deleted later in the
    /// window and is accounted for by its tombstone; a child nothing holds is
    /// in no domain value, and so in no state.
    ///
    /// - Parameters:
    ///   - changed: Inserted or updated children, by their model's entity name.
    ///   - relations: The embedding structure below the registered models.
    ///   - registered: The registered entity names.
    /// - Returns: The embedding rows' identities, by registered entity name.
    /// - Throws: Whatever a fetch throws.
    func embeddingRows(
        of changed: [String: [PersistentIdentifier]],
        relations: EmbeddedRelations,
        registered: Set<String>
    ) throws -> [String: Set<UUID>] {
        var frontier: [String: Set<UUID>] = [:]
        for (entityName, identifiers) in changed {
            guard let type = relations.modelTypes[entityName] else { continue }
            frontier[entityName, default: []].formUnion(try identities(of: identifiers, asConcrete: type).values)
        }
        var seen = frontier
        var found: [String: Set<UUID>] = [:]
        while let (entityName, ids) = frontier.popFirst() {
            for edge in relations.edgesInto[entityName] ?? [] {
                let holders = Set(try edge.parents(modelContext, Array(ids)).map(\.id))
                if registered.contains(edge.parentEntity) {
                    found[edge.parentEntity, default: []].formUnion(holders)
                    continue
                }
                // One level further up. Only identities not already followed,
                // so a cycle in the schema can't loop.
                let unseen = holders.subtracting(seen[edge.parentEntity] ?? [])
                guard !unseen.isEmpty else { continue }
                seen[edge.parentEntity, default: []].formUnion(unseen)
                frontier[edge.parentEntity, default: []].formUnion(unseen)
            }
        }
        return found
    }
}
