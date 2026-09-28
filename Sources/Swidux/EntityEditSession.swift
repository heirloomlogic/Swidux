import Foundation

/// A type-preserving value carried by a heterogeneous edit conflict.
public struct EntityEditValue: @unchecked Sendable {
    private let storage: Any

    /// Erases a typed value while retaining it for checked extraction.
    public init<Value: Sendable>(_ value: Value) {
        storage = value
    }

    /// Returns the stored value when it has the requested type.
    public func value<Value>(as type: Value.Type = Value.self) -> Value? {
        storage as? Value
    }
}

/// An entity identity that remains distinct when two entity types use the same UUID.
public struct EntityEditEntityIdentity: Hashable, Sendable {
    /// The entity's stable identifier.
    public let id: UUID
    /// The concrete entity type's runtime identity.
    public let type: ObjectIdentifier
    /// A diagnostic name for the concrete entity type.
    public let typeName: String

    init<Entity>(_ type: Entity.Type, id: UUID) {
        self.id = id
        self.type = ObjectIdentifier(type)
        typeName = String(reflecting: type)
    }
}

/// The reason a local edit group could not be applied.
public enum EntityEditConflictKind: Sendable, Equatable {
    case fieldChanged
    case missingEntity
    case associationChanged
    case restrictedAssociation
    case alreadyApplied
    case cancelledSession
}

/// A conflict against the state observed when ``EntityEditSession/apply(to:)`` ran.
public struct EntityEditConflict: Sendable {
    /// The entity whose field or association failed validation.
    public let entity: EntityEditEntityIdentity
    /// The caller-supplied field or association name.
    public let field: String
    /// The validation failure category.
    public let kind: EntityEditConflictKind
    /// The value captured when the session began.
    public let original: EntityEditValue?
    /// The value found in canonical state during application.
    public let current: EntityEditValue?
    /// The session's intended value.
    public let proposed: EntityEditValue?
}

/// A typed marker used as the proposed value for deletion conflicts.
public struct EntityEditDeletion: Sendable, Equatable {
    /// Creates a deletion marker.
    public init() {}
}

/// The result of validating and applying one local edit group.
public struct EntityEditResult: Sendable {
    /// Every conflict found during validation, in deterministic order.
    public let conflicts: [EntityEditConflict]

    /// Whether the complete group was applied.
    public var wasApplied: Bool { conflicts.isEmpty }

    static let applied = EntityEditResult(conflicts: [])
}

/// A rejected edit or association command definition.
public enum EntityEditDefinitionError: Error, Equatable {
    case missingEntity
    case entityAlreadyExists
    case identityMutation
    case duplicateFieldIdentity
    case associationOwnerMutation
    case inactiveSession
    case unregisteredAssociation
    case noAssociationsRegistered
    case invalidAssociationOwnership
    case duplicateOperation
    case referenceTypeUnsupported
    case nestedAssociationDeletionUnsupported
}

private enum EntityEditSessionState {
    case active
    case applied
    case cancelled
}

private struct EntityEditStoreIdentity: Hashable {
    let entityType: ObjectIdentifier
    let keyPath: AnyKeyPath
}

private struct EntityEditRecordIdentity: Hashable {
    let store: EntityEditStoreIdentity
    let id: UUID
}

private struct EntityEditFieldIdentity: Hashable {
    let entity: EntityEditRecordIdentity
    let keyPath: AnyKeyPath
}

private struct EntityEditFieldNameIdentity: Hashable {
    let entity: EntityEditRecordIdentity
    let name: String
}

@MainActor
private protocol AnyEntityEditDraftBox: AnyObject {
    func snapshot() -> Any
    func restore(_ snapshot: Any)
}

@MainActor
private final class EntityEditDraftBox<Entity>: AnyEntityEditDraftBox
where Entity: Identifiable & Equatable & Sendable, Entity.ID == UUID {
    let original: Entity
    var draft: Entity

    init(_ entity: Entity) {
        original = entity
        draft = entity
    }

    func snapshot() -> Any { draft }

    func restore(_ snapshot: Any) {
        guard let entity = snapshot as? Entity else { return }
        draft = entity
    }
}

@MainActor
struct EntityEditOperation<State> {
    let key: String
    let validate: (State) -> [EntityEditConflict]
    let mutate: (inout State) -> Void
}

@MainActor
private struct EntityEditFieldOperation<State> {
    let field: String
    let validate: (State) -> EntityEditConflict?
    let mutate: (inout State) -> Void
}

/// A local optimistic editing transaction over value-typed state and entities.
///
/// The session records only named fields and explicit association operations. `apply` compares them with current canonical state, validates the whole group, then mutates a staged state copy. Use it inside `Store.mutate` when applying to a live Swidux store. It does not flush persistence or provide a durable or cross-device transaction.
@MainActor
public final class EntityEditSession<State> where State: Sendable {
    private let baseline: State
    private let associations: EntityAssociationCatalog<State>
    private var lifecycle = EntityEditSessionState.active
    private var drafts: [EntityEditRecordIdentity: Any] = [:]
    private var fields: [EntityEditFieldIdentity: EntityEditFieldOperation<State>] = [:]
    private var names: [EntityEditFieldNameIdentity: AnyKeyPath] = [:]
    private var operations: [EntityEditOperation<State>] = []
    private var operationKeys: Set<String> = []
    private var destructiveEntities: Set<EntityEditRecordIdentity> = []
    private var associationChildren: Set<String> = []
    private var referencedAssociationParents: Set<String> = []
    private var deletedAssociationParents: Set<String> = []
    private var createdDrafts: [EntityEditRecordIdentity: Any] = [:]
    private var deletedDrafts: Set<EntityEditRecordIdentity> = []

    /// Captures a value-semantic baseline and the complete association catalog for this session.
    public init(state: State, associations: EntityAssociationCatalog<State> = .init()) {
        precondition(
            Mirror(reflecting: state).displayStyle != .class, "EntityEditSession requires value-typed root state.")
        baseline = state
        self.associations = associations
    }

    /// Sets one typed field in the session draft.
    public func edit<Entity, Value>(
        _ entityType: Entity.Type, id: UUID, in store: WritableKeyPath<State, EntityStore<Entity>>,
        field: WritableKeyPath<Entity, Value>, named name: String, to proposed: Value
    ) throws where Entity: Identifiable & Equatable & Sendable, Entity.ID == UUID, Value: Equatable & Sendable {
        try requireActive()
        guard !(Entity.self is AnyObject.Type) else { throw EntityEditDefinitionError.referenceTypeUnsupported }
        guard !associations.isOwnerField(store: store, field: field) else {
            throw EntityEditDefinitionError.associationOwnerMutation
        }

        let storeIdentity = EntityEditStoreIdentity(entityType: ObjectIdentifier(Entity.self), keyPath: store)
        let recordIdentity = EntityEditRecordIdentity(store: storeIdentity, id: id)
        guard !destructiveEntities.contains(recordIdentity) else { throw EntityEditDefinitionError.duplicateOperation }
        let fieldIdentity = EntityEditFieldIdentity(entity: recordIdentity, keyPath: field)
        let nameIdentity = EntityEditFieldNameIdentity(entity: recordIdentity, name: name)
        if let existingName = fields[fieldIdentity]?.field, existingName != name {
            throw EntityEditDefinitionError.duplicateFieldIdentity
        }
        if let existingPath = names[nameIdentity], existingPath != field {
            throw EntityEditDefinitionError.duplicateFieldIdentity
        }

        let box: EntityEditDraftBox<Entity>
        if let existing = drafts[recordIdentity] {
            guard let typed = existing as? EntityEditDraftBox<Entity> else {
                throw EntityEditDefinitionError.duplicateFieldIdentity
            }
            box = typed
        } else {
            guard let original = baseline[keyPath: store][id] else {
                throw EntityEditDefinitionError.missingEntity
            }
            box = EntityEditDraftBox(original)
            if let associationDraft = createdDrafts[recordIdentity] as? Entity {
                box.draft = associationDraft
            }
            drafts[recordIdentity] = box
        }
        let previous = box.draft[keyPath: field]
        box.draft[keyPath: field] = proposed
        guard box.draft.id == id else {
            box.draft[keyPath: field] = previous
            throw EntityEditDefinitionError.identityMutation
        }
        names[nameIdentity] = field

        guard fields[fieldIdentity] == nil else { return }
        let original = box.original[keyPath: field]
        let entityIdentity = EntityEditEntityIdentity(Entity.self, id: id)
        fields[fieldIdentity] = EntityEditFieldOperation(
            field: name,
            validate: { state in
                let proposed = box.draft[keyPath: field]
                guard proposed != original else { return nil }
                guard let currentEntity = state[keyPath: store][id] else {
                    return EntityEditConflict(
                        entity: entityIdentity, field: name, kind: .missingEntity, original: EntityEditValue(original),
                        current: nil, proposed: EntityEditValue(proposed))
                }
                let current = currentEntity[keyPath: field]
                guard current != original, current != proposed else { return nil }
                return EntityEditConflict(
                    entity: entityIdentity, field: name, kind: .fieldChanged, original: EntityEditValue(original),
                    current: EntityEditValue(current), proposed: EntityEditValue(proposed))
            },
            mutate: { state in
                let proposed = box.draft[keyPath: field]
                guard proposed != original else { return }
                state[keyPath: store].modify(id) { entity in
                    if entity[keyPath: field] != proposed {
                        entity[keyPath: field] = proposed
                    }
                }
            })
    }

    /// Returns the current draft for an edited or association-modified entity.
    public func draft<Entity>(
        _ entityType: Entity.Type, id: UUID, in store: WritableKeyPath<State, EntityStore<Entity>>
    ) -> Entity? where Entity: Identifiable & Equatable & Sendable, Entity.ID == UUID {
        let identity = EntityEditRecordIdentity(
            store: EntityEditStoreIdentity(entityType: ObjectIdentifier(Entity.self), keyPath: store), id: id)
        guard !deletedDrafts.contains(identity) else { return nil }
        return (drafts[identity] as? EntityEditDraftBox<Entity>)?.draft ?? createdDrafts[identity] as? Entity
    }

    /// Discards the draft and ends the session.
    public func cancel() {
        guard lifecycle == .active else { return }
        lifecycle = .cancelled
        drafts.removeAll()
        fields.removeAll()
        names.removeAll()
        operations.removeAll()
        operationKeys.removeAll()
        destructiveEntities.removeAll()
        associationChildren.removeAll()
        referencedAssociationParents.removeAll()
        deletedAssociationParents.removeAll()
        createdDrafts.removeAll()
        deletedDrafts.removeAll()
    }

    /// Validates against current canonical state and synchronously applies the complete group when conflict-free.
    public func apply(to state: inout State) -> EntityEditResult {
        switch lifecycle {
        case .applied:
            return terminalConflict(.alreadyApplied)
        case .cancelled:
            return terminalConflict(.cancelledSession)
        case .active:
            break
        }

        var conflicts = fields.values.compactMap { $0.validate(state) }
        for operation in operations {
            conflicts.append(contentsOf: operation.validate(state))
        }
        conflicts.sort {
            ($0.entity.typeName, $0.entity.id.uuidString, $0.field, String(describing: $0.kind)) < (
                $1.entity.typeName, $1.entity.id.uuidString, $1.field, String(describing: $1.kind)
            )
        }
        guard conflicts.isEmpty else { return EntityEditResult(conflicts: conflicts) }

        var staged = state
        for field in fields.values {
            field.mutate(&staged)
        }
        for operation in operations {
            operation.mutate(&staged)
        }
        state = staged
        lifecycle = .applied
        return .applied
    }

    func requireRegistered<Parent, Child>(_ association: EntityAssociation<State, Parent, Child>) throws
    where
        Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID, Child: Identifiable & Equatable & Sendable,
        Child.ID == UUID
    {
        try requireActive()
        guard associations.contains(association) else { throw EntityEditDefinitionError.unregisteredAssociation }
    }

    func append(_ operation: EntityEditOperation<State>) throws {
        try requireActive()
        guard operationKeys.insert(operation.key).inserted else { throw EntityEditDefinitionError.duplicateOperation }
        operations.append(operation)
    }

    func performCommand(_ body: () throws -> Void) throws {
        let savedOperations = operations
        let savedOperationKeys = operationKeys
        let savedDestructiveEntities = destructiveEntities
        let savedAssociationChildren = associationChildren
        let savedReferencedParents = referencedAssociationParents
        let savedDeletedParents = deletedAssociationParents
        let savedCreatedDrafts = createdDrafts
        let savedDeletedDrafts = deletedDrafts
        let savedDraftValues = drafts.compactMapValues { ($0 as? AnyEntityEditDraftBox)?.snapshot() }
        do {
            try body()
        } catch {
            operations = savedOperations
            operationKeys = savedOperationKeys
            destructiveEntities = savedDestructiveEntities
            associationChildren = savedAssociationChildren
            referencedAssociationParents = savedReferencedParents
            deletedAssociationParents = savedDeletedParents
            createdDrafts = savedCreatedDrafts
            deletedDrafts = savedDeletedDrafts
            for (identity, value) in savedDraftValues {
                (drafts[identity] as? AnyEntityEditDraftBox)?.restore(value)
            }
            throw error
        }
    }

    func registeredAssociations<Parent>(
        for store: WritableKeyPath<State, EntityStore<Parent>>
    ) throws -> [AnyEntityAssociation<State>] where Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID {
        try requireActive()
        let matches = associations.associations(for: store)
        guard !matches.isEmpty else { throw EntityEditDefinitionError.noAssociationsRegistered }
        return matches
    }

    func baselineSnapshot() -> State {
        baseline
    }

    func hasAssociations(parentStore: AnyKeyPath, parentType: ObjectIdentifier) -> Bool {
        associations.hasAssociations(parentStore: parentStore, parentType: parentType)
    }

    func registerAssociationChild<Child>(
        _ childID: UUID, store: WritableKeyPath<State, EntityStore<Child>>, association: EntityAssociationIdentity,
        deletes: Bool
    ) throws where Child: Identifiable & Equatable & Sendable, Child.ID == UUID {
        let command = "\(association):\(childID)"
        let record = EntityEditRecordIdentity(
            store: EntityEditStoreIdentity(entityType: ObjectIdentifier(Child.self), keyPath: store), id: childID)
        if deletes {
            guard !associations.hasAssociations(parentStore: store) else {
                throw EntityEditDefinitionError.nestedAssociationDeletionUnsupported
            }
            guard !fields.keys.contains(where: { $0.entity == record }) else {
                throw EntityEditDefinitionError.duplicateOperation
            }
        }
        guard associationChildren.insert(command).inserted else { throw EntityEditDefinitionError.duplicateOperation }
        if deletes { destructiveEntities.insert(record) }
    }

    func registerAssociationParent(_ parentID: UUID, association: EntityAssociationIdentity) throws {
        let key = "\(association):\(parentID)"
        guard !deletedAssociationParents.contains(key) else { throw EntityEditDefinitionError.duplicateOperation }
        referencedAssociationParents.insert(key)
    }

    func registerDeletedAssociationParent(_ parentID: UUID, association: EntityAssociationIdentity) throws {
        let key = "\(association):\(parentID)"
        guard !referencedAssociationParents.contains(key) else { throw EntityEditDefinitionError.duplicateOperation }
        deletedAssociationParents.insert(key)
    }

    func registerDestructiveEntity(_ id: UUID, type: ObjectIdentifier, store: AnyKeyPath) throws {
        let record = EntityEditRecordIdentity(store: EntityEditStoreIdentity(entityType: type, keyPath: store), id: id)
        guard !fields.keys.contains(where: { $0.entity == record }) else {
            throw EntityEditDefinitionError.duplicateOperation
        }
        destructiveEntities.insert(record)
    }

    func updateAssociationDraft<Child>(
        _ childID: UUID, store: WritableKeyPath<State, EntityStore<Child>>, _ update: (inout Child) -> Void
    ) throws where Child: Identifiable & Equatable & Sendable, Child.ID == UUID {
        let record = EntityEditRecordIdentity(
            store: EntityEditStoreIdentity(entityType: ObjectIdentifier(Child.self), keyPath: store), id: childID)
        if let box = drafts[record] as? EntityEditDraftBox<Child> {
            update(&box.draft)
        } else if var child = createdDrafts[record] as? Child ?? baseline[keyPath: store][childID] {
            update(&child)
            createdDrafts[record] = child
        } else {
            throw EntityEditDefinitionError.missingEntity
        }
        deletedDrafts.remove(record)
    }

    func setCreatedDraft<Child>(_ child: Child, store: WritableKeyPath<State, EntityStore<Child>>)
    where Child: Identifiable & Equatable & Sendable, Child.ID == UUID {
        let record = EntityEditRecordIdentity(
            store: EntityEditStoreIdentity(entityType: ObjectIdentifier(Child.self), keyPath: store), id: child.id)
        createdDrafts[record] = child
        deletedDrafts.remove(record)
    }

    func markDeletedDraft<Child>(_ childID: UUID, store: WritableKeyPath<State, EntityStore<Child>>)
    where Child: Identifiable & Equatable & Sendable, Child.ID == UUID {
        let record = EntityEditRecordIdentity(
            store: EntityEditStoreIdentity(entityType: ObjectIdentifier(Child.self), keyPath: store), id: childID)
        deletedDrafts.insert(record)
    }

    private func requireActive() throws {
        guard lifecycle == .active else { throw EntityEditDefinitionError.inactiveSession }
    }

    private func terminalConflict(_ kind: EntityEditConflictKind) -> EntityEditResult {
        EntityEditResult(conflicts: [
            EntityEditConflict(
                entity: EntityEditEntityIdentity(State.self, id: UUID.zero), field: "session", kind: kind,
                original: nil, current: nil, proposed: nil)
        ])
    }
}

extension UUID {
    fileprivate static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
