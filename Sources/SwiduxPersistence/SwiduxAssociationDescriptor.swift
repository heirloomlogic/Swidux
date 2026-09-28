import Foundation
import SwiftData

/// Invalid reciprocal declarations or an ambiguous local association graph.
public enum SwiduxAssociationError: Error, Equatable {
    case invalidInverse(entity: String, property: String)
    case duplicateIdentity(entity: String, id: UUID)
    case referencedParentDeleted(entity: String, property: String, id: UUID)
    case synchronizationUnavailable
}

/// Resolves a generated model key path through its existing domain type.
public func associationInverse<E: PersistableEntity>(_ entity: E.Type, _ property: String) -> AnyKeyPath? {
    E.swiduxAssociationInverse(property)
}

/// One generated storage edge. Domain UUIDs carry ownership and ordering; references are a local projection.
public struct SwiduxAssociationDescriptor<Model: PersistableModel> {
    let property: String
    let inverse: String
    let toMany: Bool
    let destination: any PersistableModel.Type
    let validate: () throws -> Void
    let reconcile: (ModelContext) throws -> Void

    /// Describes an owner UUID and its generated optional model reference.
    public static func belongsTo<Parent: PersistableEntity>(
        property: String, inverse: String, destination: Parent.Type,
        id: KeyPath<Model, UUID?>, reference: ReferenceWritableKeyPath<Model, Parent.Model?>
    ) -> Self {
        Self(
            property: property, inverse: inverse, toMany: false, destination: Parent.Model.self,
            validate: {
                guard
                    Parent.Model.swiduxAssociations.contains(where: {
                        $0.property == inverse && $0.inverse == property && $0.toMany
                            && ObjectIdentifier($0.destination) == ObjectIdentifier(Model.self)
                    })
                else {
                    throw SwiduxAssociationError.invalidInverse(
                        entity: String(reflecting: Model.self), property: property)
                }
            },
            reconcile: { context in
                let children = try uniqueRows(Model.self, in: context)
                let parents = try uniqueRows(Parent.Model.self, in: context)
                let deleted = Set(context.deletedModelsArray.compactMap { ($0 as? Parent.Model)?.id })
                for child in children.values {
                    let owner = child[keyPath: id]
                    if let owner, deleted.contains(owner) {
                        throw SwiduxAssociationError.referencedParentDeleted(
                            entity: String(reflecting: Model.self), property: property, id: owner)
                    }
                    child[keyPath: reference] = owner.flatMap { parents[$0] }
                }
            })
    }

    /// Describes order metadata and the inverse collection projected from child owner UUIDs.
    public static func hasMany<Child: PersistableEntity>(
        property: String, inverse: String, destination: Child.Type,
        ids: KeyPath<Model, [UUID]>, reference: ReferenceWritableKeyPath<Model, [Child.Model]?>
    ) -> Self {
        Self(
            property: property, inverse: inverse, toMany: true, destination: Child.Model.self,
            validate: {
                guard
                    Child.Model.swiduxAssociations.contains(where: {
                        $0.property == inverse && $0.inverse == property && !$0.toMany
                            && ObjectIdentifier($0.destination) == ObjectIdentifier(Model.self)
                    })
                else {
                    throw SwiduxAssociationError.invalidInverse(
                        entity: String(reflecting: Model.self), property: property)
                }
            }, reconcile: { _ in })
    }
}

private func uniqueRows<M: PersistableModel>(_ model: M.Type, in context: ModelContext) throws -> [UUID: M] {
    var result: [UUID: M] = [:]
    for row in try context.fetch(FetchDescriptor<M>()) where !row.isDeleted {
        guard result.updateValue(row, forKey: row.id) == nil else {
            throw SwiduxAssociationError.duplicateIdentity(entity: String(reflecting: M.self), id: row.id)
        }
    }
    return result
}

enum SwiduxAssociationGraph {
    static func walk(
        models: [any PersistableModel.Type], body: (any PersistableModel.Type) throws -> Void
    ) throws {
        var seen: Set<ObjectIdentifier> = []
        var pending = models
        while let model = pending.popLast() {
            guard seen.insert(ObjectIdentifier(model)).inserted else { continue }
            try body(model)
            pending.append(contentsOf: destinations(model))
        }
    }

    private static func destinations<M: PersistableModel>(_ type: M.Type) -> [any PersistableModel.Type] {
        M.swiduxAssociations.map(\.destination)
    }

    static func validate(models: [any PersistableModel.Type]) throws {
        try walk(models: models) { try validateModel($0) }
    }

    private static func validateModel<M: PersistableModel>(_ model: M.Type) throws {
        for association in M.swiduxAssociations { try association.validate() }
    }

    static func reconcile(models: [any PersistableModel.Type], in context: ModelContext) throws {
        try walk(models: models) { try reconcileModel($0, in: context) }
    }

    private static func reconcileModel<M: PersistableModel>(_ model: M.Type, in context: ModelContext) throws {
        for association in M.swiduxAssociations {
            try association.validate()
            try association.reconcile(context)
        }
    }

    static func hasAssociations<M: PersistableModel>(_ model: M.Type) -> Bool { !M.swiduxAssociations.isEmpty }
}
