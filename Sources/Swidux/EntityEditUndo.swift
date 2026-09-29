import Foundation

/// A single-use inverse of a successfully applied editing session.
///
/// Undo validates the complete group before reversing it. Fields changed by other work remain intact; conflicting fields, replacement arrivals, and observed deletions reject the group.
@MainActor
public final class EntityEditUndo<State: Sendable> {
    /// The canonical stores this inverse can change.
    public let affectedStores: Set<AnyKeyPath>
    /// Parent endpoints a durable inverse must validate before saving.
    public let readDependencies: [AnyKeyPath: Set<UUID>]
    private let operations: [EntityEditOperation<State>]
    private var consumed = false

    init(
        operations: [EntityEditOperation<State>], affectedStores: Set<AnyKeyPath>,
        readDependencies: [AnyKeyPath: Set<UUID>]
    ) {
        self.operations = operations
        self.affectedStores = affectedStores
        self.readDependencies = readDependencies
    }

    /// Validates and stages the inverse without consuming the receipt.
    public func preview(in state: State) -> (result: EntityEditResult, state: State) {
        if consumed {
            return (
                EntityEditResult(conflicts: [
                    EntityEditConflict(
                        entity: EntityEditEntityIdentity(
                            State.self, id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))),
                        field: "undo", kind: .alreadyApplied, original: nil, current: nil, proposed: nil)
                ]), state
            )
        }
        let conflicts = operations.flatMap { $0.validate(state) }
        guard conflicts.isEmpty else { return (EntityEditResult(conflicts: conflicts), state) }
        var staged = state
        for operation in operations { operation.mutate(&staged) }
        return (.applied, staged)
    }

    /// Applies the complete inverse when its guards succeed, then consumes the receipt.
    @discardableResult
    public func undo(in state: inout State) -> EntityEditResult {
        let staged = preview(in: state)
        guard staged.result.wasApplied else { return staged.result }
        state = staged.state
        consumed = true
        return staged.result
    }
}

@MainActor
func fieldUndo<State, Entity, Value>(
    before: State, after: State, store: WritableKeyPath<State, EntityStore<Entity>>, id: UUID,
    field: WritableKeyPath<Entity, Value>, name: String
) -> EntityEditOperation<State>?
where State: Sendable, Entity: Identifiable & Equatable & Sendable, Entity.ID == UUID, Value: Equatable & Sendable {
    guard let original = before[keyPath: store][id]?[keyPath: field],
        let expected = after[keyPath: store][id]?[keyPath: field], original != expected
    else { return nil }
    let arrival = after[keyPath: store].remoteArrivals[id]
    return EntityEditOperation(
        key: "undo-field:\(store):\(id):\(field)",
        validate: { state in
            let current = state[keyPath: store][id]?[keyPath: field]
            guard current == expected, !state[keyPath: store].remotelyRemovedIDs.contains(id),
                state[keyPath: store].remoteArrivals[id] == arrival
            else {
                return [
                    EntityEditConflict(
                        entity: EntityEditEntityIdentity(Entity.self, id: id), field: name,
                        kind: current == nil ? .missingEntity : .fieldChanged,
                        original: EntityEditValue(expected), current: current.map(EntityEditValue.init),
                        proposed: EntityEditValue(original))
                ]
            }
            return []
        }, mutate: { $0[keyPath: store].modify(id) { $0[keyPath: field] = original } })
}

@MainActor
func recordUndos<State, Entity>(
    before: State, after: State, store: WritableKeyPath<State, EntityStore<Entity>>
) -> [EntityEditOperation<State>]
where State: Sendable, Entity: Identifiable & Equatable & Sendable, Entity.ID == UUID {
    let original = before[keyPath: store]
    let expected = after[keyPath: store]
    let ids = Set(original.values.map(\.id)).symmetricDifference(expected.values.map(\.id))
    return ids.sorted { $0.uuidString < $1.uuidString }.map { id in
        let value = original[id]
        let applied = expected[id]
        let arrival = expected.remoteArrivals[id]
        return EntityEditOperation(
            key: "undo-record:\(store):\(id)",
            validate: { state in
                let current = state[keyPath: store][id]
                guard current == applied, !state[keyPath: store].remotelyRemovedIDs.contains(id),
                    state[keyPath: store].remoteArrivals[id] == arrival
                else {
                    return [
                        EntityEditConflict(
                            entity: EntityEditEntityIdentity(Entity.self, id: id), field: "entity",
                            kind: .associationChanged, original: applied.map(EntityEditValue.init),
                            current: current.map(EntityEditValue.init), proposed: value.map(EntityEditValue.init))
                    ]
                }
                return []
            }, mutate: { $0[keyPath: store][id] = value })
    }
}
