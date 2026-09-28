import Foundation

/// An explicit action for removing an ownership edge.
public enum EntityAssociationPolicy: Sendable, Equatable, Hashable, CaseIterable {
    case detach
    case delete
    case restrict
}

/// Whether a child may exist without this association.
public enum EntityAssociationRequiredness: Sendable, Equatable, Hashable {
    case optional
    case required
}

/// An invalid or ambiguous association declaration.
public enum EntityAssociationConfigurationError: Error, Equatable {
    case requiredAssociationCannotDetach
    case duplicateAssociationName
    case duplicateAssociationOwner
    case referenceTypeUnsupported
}

struct EntityAssociationIdentity: Hashable, Sendable {
    let name: String
    let parentType: ObjectIdentifier
    let childType: ObjectIdentifier
    let parents: ObjectIdentifier
    let children: ObjectIdentifier
    let owner: ObjectIdentifier
    let order: ObjectIdentifier?
    let requiredness: EntityAssociationRequiredness
    let removal: EntityAssociationPolicy
    let parentDeletion: EntityAssociationPolicy
}

/// A named local ownership edge between canonical parent and child entity stores.
///
/// The descriptor stores no child collection. Navigation always resolves the current stores by UUID. An unresolved parent remains observable through ``parentID(of:in:)`` even though ``parent(of:in:)`` returns `nil`.
public struct EntityAssociation<State, Parent, Child>
where
    State: Sendable, Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID,
    Child: Identifiable & Equatable & Sendable, Child.ID == UUID
{
    /// The association's conflict and registration name.
    public let name: String
    /// Whether children may be detached.
    public let requiredness: EntityAssociationRequiredness
    /// The policy for explicit child removal.
    public let removal: EntityAssociationPolicy
    /// The policy applied to children when their parent is deleted.
    public let parentDeletion: EntityAssociationPolicy
    let parents: WritableKeyPath<State, EntityStore<Parent>>
    let children: WritableKeyPath<State, EntityStore<Child>>
    let owner: WritableKeyPath<Child, UUID?>
    let order: WritableKeyPath<Parent, [UUID]>?

    /// Declares a named association and its mandatory ownership policies.
    @MainActor
    public init(
        name: String, parents: WritableKeyPath<State, EntityStore<Parent>>,
        children: WritableKeyPath<State, EntityStore<Child>>, owner: WritableKeyPath<Child, UUID?>,
        order: WritableKeyPath<Parent, [UUID]>? = nil,
        requiredness: EntityAssociationRequiredness, removal: EntityAssociationPolicy,
        parentDeletion: EntityAssociationPolicy
    ) throws {
        guard !(Parent.self is AnyObject.Type), !(Child.self is AnyObject.Type) else {
            throw EntityAssociationConfigurationError.referenceTypeUnsupported
        }
        if requiredness == .required, removal == .detach || parentDeletion == .detach {
            throw EntityAssociationConfigurationError.requiredAssociationCannotDetach
        }
        self.name = name
        self.parents = parents
        self.children = children
        self.owner = owner
        self.order = order
        self.requiredness = requiredness
        self.removal = removal
        self.parentDeletion = parentDeletion
    }

    /// Resolves a parent's current children from canonical state.
    public func children(of parentID: UUID, in state: State) -> [Child] {
        let members = state[keyPath: children].values.filter { $0[keyPath: owner] == parentID }
        guard let order, let parent = state[keyPath: parents][parentID] else { return members }
        var byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let ordered = parent[keyPath: order].compactMap { byID.removeValue(forKey: $0) }
        return ordered + byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Returns the stored owner ID even when its parent cannot be resolved.
    public func parentID(of childID: UUID, in state: State) -> UUID? {
        state[keyPath: children][childID]?[keyPath: owner]
    }

    /// Resolves a child's current parent from canonical state.
    public func parent(of childID: UUID, in state: State) -> Parent? {
        guard let parentID = parentID(of: childID, in: state) else { return nil }
        return state[keyPath: parents][parentID]
    }

    @MainActor
    var identity: EntityAssociationIdentity {
        EntityAssociationIdentity(
            name: name, parentType: ObjectIdentifier(Parent.self), childType: ObjectIdentifier(Child.self),
            parents: ObjectIdentifier(parents), children: ObjectIdentifier(children), owner: ObjectIdentifier(owner),
            order: order.map(ObjectIdentifier.init),
            requiredness: requiredness, removal: removal, parentDeletion: parentDeletion)
    }

    @MainActor
    func erase() -> AnyEntityAssociation<State> {
        let identity = identity
        return AnyEntityAssociation(
            identity: identity, parentStore: parents, childStore: children, ownerField: owner,
            parentDeletion: parentDeletion,
            linkedChildIDs: { parentID, state in
                state[keyPath: children].values.filter { $0[keyPath: owner] == parentID }.map(\.id)
            },
            makeParentDeletion: { parentID, baseline in
                guard let originalParent = baseline[keyPath: parents][parentID] else {
                    throw EntityEditDefinitionError.missingEntity
                }
                let originalChildren = baseline[keyPath: children].values.filter { $0[keyPath: owner] == parentID }
                let parentIdentity = EntityEditEntityIdentity(Parent.self, id: parentID)
                let field = name
                return EntityEditOperation(
                    key: "parent-delete:\(identity):\(parentID)",
                    validate: { state in
                        guard let currentParent = state[keyPath: parents][parentID] else {
                            return [
                                EntityEditConflict(
                                    entity: parentIdentity, field: field, kind: .missingEntity,
                                    original: EntityEditValue(originalParent), current: nil,
                                    proposed: EntityEditValue(EntityEditDeletion()))
                            ]
                        }
                        guard currentParent == originalParent else {
                            return [
                                EntityEditConflict(
                                    entity: parentIdentity, field: field, kind: .associationChanged,
                                    original: EntityEditValue(originalParent), current: EntityEditValue(currentParent),
                                    proposed: EntityEditValue(EntityEditDeletion()))
                            ]
                        }
                        let currentChildren = state[keyPath: children].values.filter { $0[keyPath: owner] == parentID }
                        let originalByID = Dictionary(uniqueKeysWithValues: originalChildren.map { ($0.id, $0) })
                        let currentByID = Dictionary(uniqueKeysWithValues: currentChildren.map { ($0.id, $0) })
                        let graphMatches =
                            originalByID.keys == currentByID.keys
                            && (parentDeletion != .delete || originalByID == currentByID)
                        guard graphMatches else {
                            return [
                                EntityEditConflict(
                                    entity: parentIdentity, field: field, kind: .associationChanged,
                                    original: EntityEditValue(originalChildren),
                                    current: EntityEditValue(currentChildren),
                                    proposed: EntityEditValue(EntityEditDeletion()))
                            ]
                        }
                        guard parentDeletion != .restrict || currentChildren.isEmpty else {
                            return [
                                EntityEditConflict(
                                    entity: parentIdentity, field: field, kind: .restrictedAssociation,
                                    original: EntityEditValue(originalChildren),
                                    current: EntityEditValue(currentChildren),
                                    proposed: EntityEditValue(EntityEditDeletion()))
                            ]
                        }
                        return []
                    },
                    mutate: { state in
                        switch parentDeletion {
                        case .detach:
                            for child in originalChildren {
                                state[keyPath: children].modify(child.id) { $0[keyPath: owner] = nil }
                            }
                        case .delete:
                            for child in originalChildren {
                                state[keyPath: children][child.id] = nil
                            }
                        case .restrict:
                            break
                        }
                    })
            })
    }
}

@MainActor
struct AnyEntityAssociation<State> where State: Sendable {
    let identity: EntityAssociationIdentity
    let parentStore: AnyKeyPath
    let childStore: AnyKeyPath
    let ownerField: AnyKeyPath
    let parentDeletion: EntityAssociationPolicy
    let linkedChildIDs: (UUID, State) -> [UUID]
    let makeParentDeletion: (UUID, State) throws -> EntityEditOperation<State>
}

/// The complete set of named associations an edit session may modify.
///
/// Parent deletion consults every catalog entry for that parent store. Supplying no entries rejects deletion instead of assuming the graph is empty.
@MainActor
public struct EntityAssociationCatalog<State> where State: Sendable {
    private var entries: [AnyEntityAssociation<State>] = []
    private var undoStores: [AnyKeyPath: (State, State) -> [EntityEditOperation<State>]] = [:]
    private var undoEdges: [(State, State) -> [EntityEditOperation<State>]] = []

    /// Creates an empty catalog.
    public init() {}

    /// Registers one named association, rejecting name and owner-field aliases.
    public mutating func register<Parent, Child>(_ association: EntityAssociation<State, Parent, Child>) throws
    where
        Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID, Child: Identifiable & Equatable & Sendable,
        Child.ID == UUID
    {
        let candidate = association.erase()
        if entries.contains(where: {
            $0.identity.parentType == candidate.identity.parentType && $0.parentStore == candidate.parentStore
                && $0.identity.name == candidate.identity.name
        }) {
            throw EntityAssociationConfigurationError.duplicateAssociationName
        }
        if entries.contains(where: {
            $0.identity.childType == candidate.identity.childType && $0.childStore == candidate.childStore
                && $0.ownerField == candidate.ownerField
        }) {
            throw EntityAssociationConfigurationError.duplicateAssociationOwner
        }
        undoStores[association.parents] = { before, after in
            recordUndos(before: before, after: after, store: association.parents)
        }
        undoStores[association.children] = { before, after in
            recordUndos(before: before, after: after, store: association.children)
        }
        undoEdges.append { before, after in
            var operations: [EntityEditOperation<State>] = []
            for child in before[keyPath: association.children].values {
                let operation = fieldUndo(
                    before: before, after: after, store: association.children,
                    id: child.id, field: association.owner, name: association.name)
                let restoresChild = after[keyPath: association.children][child.id] == nil
                guard operation != nil || restoresChild else { continue }
                if let operation { operations.append(operation) }
                if let parentID = child[keyPath: association.owner],
                    after[keyPath: association.parents][parentID] != nil
                {
                    operations.append(
                        EntityEditOperation(
                            key: "undo-parent:\(association.name):\(parentID)",
                            validate: { state in
                                guard state[keyPath: association.parents][parentID] == nil else { return [] }
                                return [
                                    EntityEditConflict(
                                        entity: EntityEditEntityIdentity(Parent.self, id: parentID),
                                        field: association.name, kind: .missingEntity,
                                        original: EntityEditValue(parentID), current: nil, proposed: nil)
                                ]
                            }, mutate: { _ in }))
                }
            }
            for parent in after[keyPath: association.parents].values
            where before[keyPath: association.parents][parent.id] == nil {
                let expectedChildren = Set(association.children(of: parent.id, in: after).map(\.id))
                operations.append(
                    EntityEditOperation(
                        key: "undo-dependents:\(association.name):\(parent.id)",
                        validate: { state in
                            let currentChildren = Set(association.children(of: parent.id, in: state).map(\.id))
                            guard currentChildren != expectedChildren else { return [] }
                            return [
                                EntityEditConflict(
                                    entity: EntityEditEntityIdentity(Parent.self, id: parent.id),
                                    field: association.name, kind: .associationChanged,
                                    original: EntityEditValue(expectedChildren),
                                    current: EntityEditValue(currentChildren),
                                    proposed: EntityEditValue(EntityEditDeletion()))
                            ]
                        }, mutate: { _ in }))
            }
            return operations
        }
        entries.append(candidate)
    }

    func undoOperations(before: State, after: State) -> [EntityEditOperation<State>] {
        undoStores.values.flatMap { $0(before, after) } + undoEdges.flatMap { $0(before, after) }
    }

    func contains<Parent, Child>(_ association: EntityAssociation<State, Parent, Child>) -> Bool
    where
        Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID, Child: Identifiable & Equatable & Sendable,
        Child.ID == UUID
    {
        entries.contains { $0.identity == association.identity }
    }

    func isOwnerField<Entity, Value>(
        store: WritableKeyPath<State, EntityStore<Entity>>, field: WritableKeyPath<Entity, Value>
    ) -> Bool where Entity: Identifiable & Equatable & Sendable, Entity.ID == UUID {
        entries.contains {
            $0.identity.childType == ObjectIdentifier(Entity.self) && $0.childStore == store && $0.ownerField == field
        }
    }

    func associations<Parent>(for store: WritableKeyPath<State, EntityStore<Parent>>) -> [AnyEntityAssociation<State>]
    where Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID {
        entries.filter { $0.identity.parentType == ObjectIdentifier(Parent.self) && $0.parentStore == store }
    }

    func hasAssociations<Parent>(parentStore: WritableKeyPath<State, EntityStore<Parent>>) -> Bool
    where Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID {
        entries.contains { $0.identity.parentType == ObjectIdentifier(Parent.self) && $0.parentStore == parentStore }
    }

    func hasAssociations(parentStore: AnyKeyPath, parentType: ObjectIdentifier) -> Bool {
        entries.contains { $0.identity.parentType == parentType && $0.parentStore == parentStore }
    }
}

@MainActor
extension EntityEditSession {
    /// Replaces order metadata without changing ownership or dropping unresolved IDs.
    public func reorder<Parent, Child>(
        _ ids: [UUID], for parentID: UUID, through association: EntityAssociation<State, Parent, Child>
    ) throws
    where
        Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID,
        Child: Identifiable & Equatable & Sendable, Child.ID == UUID
    {
        try requireRegistered(association)
        guard let order = association.order, Set(ids).count == ids.count else {
            throw EntityEditDefinitionError.invalidAssociationOwnership
        }
        try edit(
            Parent.self, id: parentID, in: association.parents, field: order, named: association.name + ".order",
            to: ids)
    }

    /// Queues creation of a child owned by an existing parent.
    public func create<Parent, Child>(
        _ child: Child, for parentID: UUID, through association: EntityAssociation<State, Parent, Child>
    ) throws
    where
        Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID, Child: Identifiable & Equatable & Sendable,
        Child.ID == UUID
    {
        try performCommand {
            try requireRegistered(association)
            let baseline = baselineSnapshot()
            guard baseline[keyPath: association.parents][parentID] != nil else {
                throw EntityEditDefinitionError.missingEntity
            }
            guard baseline[keyPath: association.children][child.id] == nil else {
                throw EntityEditDefinitionError.entityAlreadyExists
            }
            try registerAssociationChild(
                child.id, store: association.children, association: association.identity, creates: true, deletes: false)
            try registerAssociationParent(parentID, association: association.identity, store: association.parents)
            var ownedChild = child
            ownedChild[keyPath: association.owner] = parentID
            let createdDraft = setCreatedDraft(ownedChild, store: association.children)
            let childIdentity = EntityEditEntityIdentity(Child.self, id: child.id)
            try append(
                EntityEditOperation(
                    key: "create:\(association.identity):\(child.id)",
                    validate: { state in
                        guard state[keyPath: association.parents][parentID] != nil else {
                            return [
                                EntityEditConflict(
                                    entity: EntityEditEntityIdentity(Parent.self, id: parentID),
                                    field: association.name, kind: .missingEntity, original: nil, current: nil,
                                    proposed: EntityEditValue(parentID))
                            ]
                        }
                        guard let current = state[keyPath: association.children][child.id] else { return [] }
                        return [
                            EntityEditConflict(
                                entity: childIdentity, field: association.name, kind: .associationChanged,
                                original: nil, current: EntityEditValue(current),
                                proposed: EntityEditValue(createdDraft.draft))
                        ]
                    },
                    mutate: { state in
                        state[keyPath: association.children][child.id] = createdDraft.draft
                    }))
        }
    }

    /// Queues explicit removal according to the association's removal policy.
    public func remove<Parent, Child>(
        _ childID: UUID, from parentID: UUID, through association: EntityAssociation<State, Parent, Child>
    ) throws
    where
        Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID, Child: Identifiable & Equatable & Sendable,
        Child.ID == UUID
    {
        try performCommand {
            try requireRegistered(association)
            let baseline = baselineSnapshot()
            guard baseline[keyPath: association.parents][parentID] != nil,
                let original = baseline[keyPath: association.children][childID]
            else {
                throw EntityEditDefinitionError.missingEntity
            }
            guard original[keyPath: association.owner] == parentID else {
                throw EntityEditDefinitionError.invalidAssociationOwnership
            }
            try registerAssociationChild(
                childID, store: association.children, association: association.identity,
                deletes: association.removal == .delete)
            try registerAssociationParent(parentID, association: association.identity, store: association.parents)
            if association.removal == .delete {
                markDeletedDraft(childID, store: association.children)
            } else {
                try updateAssociationDraft(childID, store: association.children) {
                    $0[keyPath: association.owner] = nil
                }
            }
            let identity = EntityEditEntityIdentity(Child.self, id: childID)
            try append(
                EntityEditOperation(
                    key: "remove:\(association.identity):\(childID)",
                    validate: { state in
                        guard state[keyPath: association.parents][parentID] != nil else {
                            return [
                                EntityEditConflict(
                                    entity: EntityEditEntityIdentity(Parent.self, id: parentID),
                                    field: association.name, kind: .missingEntity, original: nil, current: nil,
                                    proposed: nil)
                            ]
                        }
                        guard let current = state[keyPath: association.children][childID] else {
                            return [
                                EntityEditConflict(
                                    entity: identity, field: association.name, kind: .missingEntity,
                                    original: EntityEditValue(original), current: nil,
                                    proposed: association.removal == .delete
                                        ? EntityEditValue(EntityEditDeletion()) : EntityEditValue(Optional<UUID>.none))
                            ]
                        }
                        guard current[keyPath: association.owner] == parentID,
                            association.removal != .delete || current == original
                        else {
                            return [
                                EntityEditConflict(
                                    entity: identity, field: association.name, kind: .associationChanged,
                                    original: EntityEditValue(original), current: EntityEditValue(current),
                                    proposed: association.removal == .delete
                                        ? EntityEditValue(EntityEditDeletion()) : EntityEditValue(Optional<UUID>.none))
                            ]
                        }
                        guard association.removal != .restrict else {
                            return [
                                EntityEditConflict(
                                    entity: identity, field: association.name, kind: .restrictedAssociation,
                                    original: EntityEditValue(parentID), current: EntityEditValue(parentID),
                                    proposed: EntityEditValue(Optional<UUID>.none))
                            ]
                        }
                        return []
                    },
                    mutate: { state in
                        switch association.removal {
                        case .detach:
                            state[keyPath: association.children].modify(childID) {
                                $0[keyPath: association.owner] = nil
                            }
                        case .delete:
                            state[keyPath: association.children][childID] = nil
                        case .restrict:
                            break
                        }
                    }))
        }
    }

    /// Queues an identity-preserving ownership move without invoking removal policy.
    public func reparent<Parent, Child>(
        _ childID: UUID, from sourceParentID: UUID, to destinationParentID: UUID,
        through association: EntityAssociation<State, Parent, Child>
    ) throws
    where
        Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID, Child: Identifiable & Equatable & Sendable,
        Child.ID == UUID
    {
        try performCommand {
            try requireRegistered(association)
            let baseline = baselineSnapshot()
            guard baseline[keyPath: association.parents][sourceParentID] != nil,
                baseline[keyPath: association.parents][destinationParentID] != nil,
                let original = baseline[keyPath: association.children][childID]
            else {
                throw EntityEditDefinitionError.missingEntity
            }
            guard original[keyPath: association.owner] == sourceParentID else {
                throw EntityEditDefinitionError.invalidAssociationOwnership
            }
            try registerAssociationChild(
                childID, store: association.children, association: association.identity, deletes: false)
            try registerAssociationParent(sourceParentID, association: association.identity, store: association.parents)
            try registerAssociationParent(
                destinationParentID, association: association.identity, store: association.parents)
            try updateAssociationDraft(childID, store: association.children) {
                $0[keyPath: association.owner] = destinationParentID
            }
            let identity = EntityEditEntityIdentity(Child.self, id: childID)
            try append(
                EntityEditOperation(
                    key: "reparent:\(association.identity):\(childID)",
                    validate: { state in
                        guard state[keyPath: association.parents][sourceParentID] != nil,
                            state[keyPath: association.parents][destinationParentID] != nil
                        else {
                            return [
                                EntityEditConflict(
                                    entity: identity, field: association.name, kind: .missingEntity,
                                    original: EntityEditValue(sourceParentID), current: nil,
                                    proposed: EntityEditValue(destinationParentID))
                            ]
                        }
                        guard let current = state[keyPath: association.children][childID] else {
                            return [
                                EntityEditConflict(
                                    entity: identity, field: association.name, kind: .missingEntity,
                                    original: EntityEditValue(sourceParentID), current: nil,
                                    proposed: EntityEditValue(destinationParentID))
                            ]
                        }
                        let currentOwner = current[keyPath: association.owner]
                        guard currentOwner == sourceParentID else {
                            return [
                                EntityEditConflict(
                                    entity: identity, field: association.name, kind: .associationChanged,
                                    original: EntityEditValue(Optional(sourceParentID)),
                                    current: EntityEditValue(currentOwner),
                                    proposed: EntityEditValue(Optional(destinationParentID)))
                            ]
                        }
                        return []
                    },
                    mutate: { state in
                        state[keyPath: association.children].modify(childID) {
                            $0[keyPath: association.owner] = destinationParentID
                        }
                    }))
        }
    }

    /// Queues parent deletion using every association registered for its canonical store.
    public func deleteParent<Parent>(_ parentID: UUID, from store: WritableKeyPath<State, EntityStore<Parent>>) throws
    where Parent: Identifiable & Equatable & Sendable, Parent.ID == UUID {
        try performCommand {
            let registered = try registeredAssociations(for: store)
            let baseline = baselineSnapshot()
            guard let original = baseline[keyPath: store][parentID] else {
                throw EntityEditDefinitionError.missingEntity
            }
            if registered.contains(where: {
                $0.parentDeletion == .delete && !$0.linkedChildIDs(parentID, baseline).isEmpty
                    && hasAssociations(parentStore: $0.childStore, parentType: $0.identity.childType)
            }) {
                throw EntityEditDefinitionError.nestedAssociationDeletionUnsupported
            }
            try registerDestructiveEntity(parentID, type: ObjectIdentifier(Parent.self), store: store)
            for association in registered {
                if association.parentDeletion != .restrict,
                    !association.linkedChildIDs(parentID, baseline).isEmpty
                {
                    markAffectedAssociationStore(association.childStore)
                }
                if association.parentDeletion == .delete {
                    for childID in association.linkedChildIDs(parentID, baseline) {
                        try registerDestructiveEntity(
                            childID, type: association.identity.childType, store: association.childStore)
                    }
                }
                try registerDeletedAssociationParent(parentID, association: association.identity)
                try append(try association.makeParentDeletion(parentID, baseline))
            }
            let identity = EntityEditEntityIdentity(Parent.self, id: parentID)
            try append(
                EntityEditOperation(
                    key: "delete-parent:\(ObjectIdentifier(Parent.self)):\(store):\(parentID)",
                    validate: { state in
                        guard let current = state[keyPath: store][parentID] else {
                            return [
                                EntityEditConflict(
                                    entity: identity, field: "entity", kind: .missingEntity,
                                    original: EntityEditValue(original), current: nil,
                                    proposed: EntityEditValue(EntityEditDeletion()))
                            ]
                        }
                        guard current == original else {
                            return [
                                EntityEditConflict(
                                    entity: identity, field: "entity", kind: .associationChanged,
                                    original: EntityEditValue(original), current: EntityEditValue(current),
                                    proposed: EntityEditValue(EntityEditDeletion()))
                            ]
                        }
                        return []
                    },
                    mutate: { state in
                        state[keyPath: store][parentID] = nil
                    }))
        }
    }
}
