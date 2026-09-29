import Foundation
import Swidux
import SwiftData

/// A canonical store participating in durable edit-session commits.
@MainActor
public struct EntityEditPersistenceRegistration<State: Sendable> {
    let keyPath: AnyKeyPath
    let append: (State, State, inout EntityPersistenceGroup) throws -> Void
    let acknowledge: (State, inout State, UUID) -> Void
    let expect: (State, Set<UUID>, inout EntityPersistenceGroup) -> Void

    /// Registers a canonical entity collection for grouped persistence.
    public static func entity<E: PersistableEntity>(
        _ keyPath: WritableKeyPath<State, EntityStore<E>>
    ) -> Self {
        Self(
            keyPath: keyPath,
            append: { original, proposed, group in
                try group.changes(from: original[keyPath: keyPath], to: proposed[keyPath: keyPath])
            },
            acknowledge: { original, proposed, transaction in
                let before = original[keyPath: keyPath]
                let after = proposed[keyPath: keyPath]
                let changed = Set(before.values.map(\.id)).union(after.values.map(\.id)).filter {
                    before[$0] != after[$0]
                }
                proposed[keyPath: keyPath].acknowledgePersisted(changed, deletionTransaction: transaction)
            },
            expect: { state, ids, group in
                for id in ids { if let entity = state[keyPath: keyPath][id] { group.expect(entity) } }
            })
    }
}

/// A session whose store dependencies do not match its persistence registration.
public enum EntityEditPersistenceError: Error, Equatable {
    case duplicateRegistration
    case unregisteredStore
}

/// Commits an editing session to disk and canonical state without a suspension point.
///
/// Construction selects grouped writes for this container. Ordinary `EntityDB` writes, including queued coordinator flushes, then throw `groupedWritesRequired`. Use this writer for all changes in the container; coordinator hydration remains available. Raw SwiftData writers and other processes are outside this serialization boundary.
@MainActor
public final class EntityEditPersistence<State: Sendable> {
    private let container: ModelContainer
    private let entities: [EntityEditPersistenceRegistration<State>]
    private let registered: Set<AnyKeyPath>

    /// Registers every participating store and reserves this container for grouped writes.
    public init(container: ModelContainer, entities: [EntityEditPersistenceRegistration<State>]) throws {
        let registered = Set(entities.map(\.keyPath))
        guard registered.count == entities.count else { throw EntityEditPersistenceError.duplicateRegistration }
        self.container = container
        self.entities = entities
        self.registered = registered
        let gate = EntityPersistenceGate.forContainer(container)
        gate.lock.lock()
        gate.requiresGroups = true
        gate.lock.unlock()
    }

    /// Persists a guarded inverse before publishing its restored fields and entities.
    @discardableResult
    public func undo(_ receipt: EntityEditUndo<State>, in state: inout State) throws -> EntityEditResult {
        guard receipt.affectedStores.union(receipt.readDependencies.keys).isSubset(of: registered) else {
            throw EntityEditPersistenceError.unregisteredStore
        }
        let staged = receipt.preview(in: state)
        guard staged.result.wasApplied else { return staged.result }
        let transaction = try persist(from: state, to: staged.state, dependencies: receipt.readDependencies)
        let original = state
        let result = receipt.undo(in: &state)
        for entity in entities { entity.acknowledge(original, &state, transaction) }
        return result
    }

    /// Saves a staged session, then publishes it. A conflict or storage error retains the draft and canonical state.
    @discardableResult
    public func commit(_ session: EntityEditSession<State>, to state: inout State) throws -> EntityEditResult {
        guard session.affectedStores.union(session.readDependencies.keys).isSubset(of: registered) else {
            throw EntityEditPersistenceError.unregisteredStore
        }
        let staged = session.preview(applyingTo: state)
        guard staged.result.wasApplied else { return staged.result }
        let transaction = try persist(from: state, to: staged.state, dependencies: session.readDependencies)
        let original = state
        let result = session.apply(to: &state)
        for entity in entities { entity.acknowledge(original, &state, transaction) }
        return result
    }
    private func persist(from state: State, to proposed: State, dependencies: [AnyKeyPath: Set<UUID>]) throws -> UUID {
        var group = EntityPersistenceGroup()
        for entity in entities {
            try entity.append(state, proposed, &group)
            entity.expect(state, dependencies[entity.keyPath] ?? [], &group)
        }
        let gate = EntityPersistenceGate.forContainer(container)
        gate.lock.lock()
        defer { gate.lock.unlock() }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let transaction = UUID()
        context.author = EntityEditTransaction.author(transaction)
        try group.apply(in: context)
        return transaction
    }
}

enum EntityEditTransaction {
    private static let prefix = "swidux.group."

    static func author(_ id: UUID) -> String { prefix + id.uuidString }

    static func id(from author: String?) -> UUID? {
        guard let author, author.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(author.dropFirst(prefix.count)))
    }
}
