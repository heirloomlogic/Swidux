import Foundation
import Swidux
import SwiftData

/// A rejected durable write, retaining the typed values that were compared.
public struct EntityPersistenceConflict: Error, Sendable {
    /// The concrete domain type whose stored value failed validation.
    public let entityType: String
    /// The conflicting domain identity.
    public let id: UUID
    /// The value expected by the grouped writer.
    public let original: EntityEditValue?
    /// The value read from storage, or nil if the row is absent.
    public let current: EntityEditValue?
    /// The requested value, or nil for deletion.
    public let proposed: EntityEditValue?
}

/// An invalid grouped write or a write through the wrong persistence path.
public enum EntityPersistenceGroupError: Error, Equatable {
    case identityMutation
    case duplicateOperation
    case ambiguousIdentity(entity: String, id: UUID)
    case groupedWritesRequired
}

/// Expected-value changes committed in one local SwiftData save.
///
/// Every guard is checked before any mutation. Conversion or save failure rolls back the complete group. Guards cover locally observed rows; they are not a cross-process or CloudKit compare-and-swap.
public struct EntityPersistenceGroup: Sendable {
    private var identities: Set<String> = []
    private var changes: [@Sendable (ModelContext) throws -> () throws -> Void] = []
    private var models: [any PersistableModel.Type] = []

    /// Creates an empty transaction.
    public init() {}

    /// Adds an insert, update, or deletion with its expected stored value.
    public mutating func change<E: PersistableEntity>(from original: E?, to proposed: E?) throws {
        guard let id = original?.id ?? proposed?.id else { return }
        guard original == nil || proposed == nil || original?.id == proposed?.id else {
            throw EntityPersistenceGroupError.identityMutation
        }
        let identity = "\(String(reflecting: E.self)):\(id)"
        guard identities.insert(identity).inserted else { throw EntityPersistenceGroupError.duplicateOperation }
        models.append(E.Model.self)
        changes.append { context in
            let rows = try context.fetch(E.Model.swiduxBatchFetchDescriptor(ids: [id]))
            guard rows.count <= 1 else {
                throw EntityPersistenceGroupError.ambiguousIdentity(entity: String(reflecting: E.self), id: id)
            }
            let current = try rows.first?.toDomain()
            guard current == original else {
                throw EntityPersistenceConflict(
                    entityType: String(reflecting: E.self), id: id,
                    original: original.map(EntityEditValue.init), current: current.map(EntityEditValue.init),
                    proposed: proposed.map(EntityEditValue.init))
            }
            return {
                if let proposed {
                    if let row = rows.first {
                        try row.update(from: proposed)
                    } else {
                        context.insert(try E.Model(from: proposed))
                    }
                } else if let row = rows.first {
                    context.delete(row)
                }
            }
        }
    }

    /// Requires an unchanged endpoint to remain present with its observed value.
    public mutating func expect<E: PersistableEntity>(_ entity: E) {
        changes.append { context in
            let rows = try context.fetch(E.Model.swiduxBatchFetchDescriptor(ids: [entity.id]))
            guard rows.count <= 1 else {
                throw EntityPersistenceGroupError.ambiguousIdentity(entity: String(reflecting: E.self), id: entity.id)
            }
            let current = try rows.first?.toDomain()
            guard current == entity else {
                throw EntityPersistenceConflict(
                    entityType: String(reflecting: E.self), id: entity.id,
                    original: EntityEditValue(entity), current: current.map(EntityEditValue.init),
                    proposed: EntityEditValue(entity))
            }
            return {}
        }
    }

    /// Adds only changed identities from two canonical stores.
    public mutating func changes<E: PersistableEntity>(
        from original: EntityStore<E>, to proposed: EntityStore<E>
    ) throws {
        let ids = Set(original.values.map(\.id)).union(proposed.values.map(\.id))
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) where original[id] != proposed[id] {
            try change(from: original[id], to: proposed[id])
        }
    }

    func apply(in context: ModelContext) throws {
        do {
            let mutations = try changes.map { try $0(context) }
            for mutate in mutations { try mutate() }
            try SwiduxAssociationGraph.reconcile(models: models, in: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

extension EntityDB {
    /// Commits all entity types in one transaction without partial-row retry.
    public func apply(_ group: EntityPersistenceGroup) throws {
        let gate = EntityPersistenceGate.forContainer(modelContainer)
        gate.lock.lock()
        defer { gate.lock.unlock() }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        try group.apply(in: context)
    }
}

/// Serializes package writers and fences queued debounced writes after grouped mode is selected.
final class EntityPersistenceGate: @unchecked Sendable {
    private struct Entry {
        weak var container: ModelContainer?
        let gate: EntityPersistenceGate
    }
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [ObjectIdentifier: Entry] = [:]
    let lock = NSRecursiveLock()
    var requiresGroups = false

    static func forContainer(_ container: ModelContainer) -> EntityPersistenceGate {
        registryLock.lock()
        defer { registryLock.unlock() }
        registry = registry.filter { $0.value.container != nil }
        let identity = ObjectIdentifier(container)
        if let existing = registry[identity] { return existing.gate }
        let gate = EntityPersistenceGate()
        registry[identity] = Entry(container: container, gate: gate)
        return gate
    }
}
