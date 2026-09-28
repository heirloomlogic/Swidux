import Foundation
import Testing

@testable import Swidux

private struct AssociationParent: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
}

private struct AssociationChild: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var primaryParentID: UUID?
    var secondaryParentID: UUID?
}

private struct OtherParent: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
}

private struct AssociationGrandchild: Identifiable, Equatable, Sendable {
    let id: UUID
    var childParentID: UUID?
}

private struct AssociationState: Equatable, Sendable {
    var parents = EntityStore<AssociationParent>()
    var otherParents = EntityStore<OtherParent>()
    var children = EntityStore<AssociationChild>()
    var grandchildren = EntityStore<AssociationGrandchild>()
}

@MainActor
@Suite("Named entity associations")
struct EntityAssociationTests {
    fileprivate typealias Association = EntityAssociation<AssociationState, AssociationParent, AssociationChild>

    @Test("navigation resolves the current canonical parent and children")
    func canonicalNavigation() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: parent.id, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([parent]), children: EntityStore([child]))
        let association = try primaryAssociation(removal: .detach, parentDeletion: .detach)

        #expect(association.children(of: parent.id, in: state) == [child])
        #expect(association.parent(of: child.id, in: state) == parent)
        state.parents.modify(parent.id) { $0.name = "Current parent" }
        #expect(association.parent(of: child.id, in: state)?.name == "Current parent")

        let missingParentID = UUID()
        state.children.modify(child.id) { $0.primaryParentID = missingParentID }
        #expect(association.parent(of: child.id, in: state) == nil)
        #expect(association.parentID(of: child.id, in: state) == missingParentID)
    }

    @Test("creation through a parent preserves the supplied local identity")
    func createChildThroughParent() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: nil, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([parent]))
        let association = try primaryAssociation(removal: .detach, parentDeletion: .restrict)
        let session = try editSession(state: state, associations: [association])
        try session.create(child, for: parent.id, through: association)

        #expect(
            session.draft(AssociationChild.self, id: child.id, in: \AssociationState.children)?.primaryParentID
                == parent.id)
        #expect(session.apply(to: &state).wasApplied)
        #expect(state.children[child.id]?.id == child.id)
        #expect(state.children[child.id]?.primaryParentID == parent.id)
    }

    @Test("a child created in the session remains editable")
    func createdChildCanBeEdited() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let child = AssociationChild(id: UUID(), name: "Original", primaryParentID: nil, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([parent]))
        let association = try primaryAssociation(removal: .detach, parentDeletion: .restrict)
        let session = try editSession(state: state, associations: [association])
        try session.create(child, for: parent.id, through: association)
        try session.edit(
            AssociationChild.self, id: child.id, in: \AssociationState.children, field: \AssociationChild.name,
            named: "name", to: "Draft")

        #expect(session.draft(AssociationChild.self, id: child.id, in: \AssociationState.children)?.name == "Draft")
        #expect(session.apply(to: &state).wasApplied)
        #expect(state.children[child.id]?.name == "Draft")
        #expect(state.children[child.id]?.primaryParentID == parent.id)
    }

    @Test("a rejected group retains edits to a child created in the session")
    func rejectedGroupRetainsCreatedChildEdit() throws {
        let parent = AssociationParent(id: UUID(), name: "Original parent")
        let child = AssociationChild(id: UUID(), name: "Original child", primaryParentID: nil, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([parent]))
        let association = try primaryAssociation(removal: .detach, parentDeletion: .restrict)
        let session = try editSession(state: state, associations: [association])
        try session.create(child, for: parent.id, through: association)
        try session.edit(
            AssociationChild.self, id: child.id, in: \AssociationState.children, field: \AssociationChild.name,
            named: "name", to: "Draft child")
        try session.edit(
            AssociationParent.self, id: parent.id, in: \AssociationState.parents, field: \AssociationParent.name,
            named: "name", to: "Draft parent")
        state.parents.modify(parent.id) { $0.name = "Current parent" }

        #expect(session.apply(to: &state).conflicts.map(\.field) == ["name"])
        #expect(state.children[child.id] == nil)
        #expect(
            session.draft(AssociationChild.self, id: child.id, in: \AssociationState.children)?.name == "Draft child")
    }

    @Test("the same child cannot be created through two named associations")
    func createdChildCannotOverlapNamedAssociations() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: nil, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([parent]))
        let primary = try primaryAssociation(removal: .detach, parentDeletion: .restrict)
        let secondary = try secondaryAssociation(removal: .detach, parentDeletion: .restrict)
        let session = try editSession(state: state, associations: [primary, secondary])
        try session.create(child, for: parent.id, through: primary)

        #expect(throws: EntityEditDefinitionError.duplicateOperation) {
            try session.create(child, for: parent.id, through: secondary)
        }
        #expect(session.apply(to: &state).wasApplied)
        #expect(state.children[child.id]?.primaryParentID == parent.id)
        #expect(state.children[child.id]?.secondaryParentID == nil)
    }

    @Test(arguments: [EntityAssociationPolicy.detach, .delete, .restrict])
    func explicitRemovalPolicy(policy: EntityAssociationPolicy) throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: parent.id, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([parent]), children: EntityStore([child]))
        let association = try primaryAssociation(removal: policy, parentDeletion: .restrict)
        let session = try editSession(state: state, associations: [association])
        try session.remove(child.id, from: parent.id, through: association)

        let result = session.apply(to: &state)
        switch policy {
        case .detach:
            #expect(result.wasApplied)
            #expect(state.children[child.id]?.primaryParentID == nil)
        case .delete:
            #expect(result.wasApplied)
            #expect(state.children[child.id] == nil)
        case .restrict:
            #expect(!result.wasApplied)
            #expect(result.conflicts.first?.kind == .restrictedAssociation)
            #expect(state.children[child.id] == child)
        }
    }

    @Test("required associations reject either detach policy")
    func requiredAssociationCannotDetach() {
        #expect(throws: EntityAssociationConfigurationError.requiredAssociationCannotDetach) {
            _ = try primaryAssociation(requiredness: .required, removal: .detach, parentDeletion: .delete)
        }
        #expect(throws: EntityAssociationConfigurationError.requiredAssociationCannotDetach) {
            _ = try primaryAssociation(requiredness: .required, removal: .delete, parentDeletion: .detach)
        }
    }

    @Test("reparent preserves identity and bypasses delete-on-remove")
    func explicitReparentBypassesRemoval() throws {
        let first = AssociationParent(id: UUID(), name: "First")
        let second = AssociationParent(id: UUID(), name: "Second")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: first.id, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([first, second]), children: EntityStore([child]))
        let association = try primaryAssociation(removal: .delete, parentDeletion: .delete)
        let session = try editSession(state: state, associations: [association])
        try session.reparent(child.id, from: first.id, to: second.id, through: association)

        #expect(
            session.draft(AssociationChild.self, id: child.id, in: \AssociationState.children)?.primaryParentID
                == second.id)

        #expect(session.apply(to: &state).wasApplied)
        #expect(state.children[child.id]?.id == child.id)
        #expect(state.children[child.id]?.primaryParentID == second.id)
    }

    @Test("overlapping parent deletion and reparent are rejected before apply")
    func overlappingGraphCommandsReject() throws {
        let first = AssociationParent(id: UUID(), name: "First")
        let second = AssociationParent(id: UUID(), name: "Second")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: first.id, secondaryParentID: nil)
        let state = AssociationState(parents: EntityStore([first, second]), children: EntityStore([child]))
        let association = try primaryAssociation(removal: .delete, parentDeletion: .delete)
        let session = try editSession(state: state, associations: [association])
        try session.reparent(child.id, from: first.id, to: second.id, through: association)

        #expect(throws: EntityEditDefinitionError.duplicateOperation) {
            try session.deleteParent(second.id, from: \AssociationState.parents)
        }
    }

    @Test("a rejected parent-delete command leaves earlier queued operations unchanged")
    func rejectedParentDeleteHasStrongExceptionSafety() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let existing = AssociationChild(
            id: UUID(), name: "Existing", primaryParentID: parent.id, secondaryParentID: nil)
        let created = AssociationChild(id: UUID(), name: "Created", primaryParentID: nil, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([parent]), children: EntityStore([existing]))
        let primary = try primaryAssociation(removal: .detach, parentDeletion: .detach)
        let secondary = try secondaryAssociation(removal: .detach, parentDeletion: .detach)
        let session = try editSession(state: state, associations: [primary, secondary])
        try session.create(created, for: parent.id, through: secondary)

        #expect(throws: EntityEditDefinitionError.duplicateOperation) {
            try session.deleteParent(parent.id, from: \AssociationState.parents)
        }
        #expect(session.apply(to: &state).wasApplied)
        #expect(state.parents[parent.id] == parent)
        #expect(state.children[existing.id]?.primaryParentID == parent.id)
        #expect(state.children[created.id]?.secondaryParentID == parent.id)
    }

    @Test("nested delete is rejected instead of leaving a registered grandchild dangling")
    func nestedDeleteRejects() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: parent.id, secondaryParentID: nil)
        let grandchild = AssociationGrandchild(id: UUID(), childParentID: child.id)
        let state = AssociationState(
            parents: EntityStore([parent]), children: EntityStore([child]), grandchildren: EntityStore([grandchild]))
        let parentChildren = try primaryAssociation(removal: .delete, parentDeletion: .delete)
        let childGrandchildren = try EntityAssociation<AssociationState, AssociationChild, AssociationGrandchild>(
            name: "grandchildren", parents: \AssociationState.children, children: \AssociationState.grandchildren,
            owner: \AssociationGrandchild.childParentID, requiredness: .optional, removal: .detach,
            parentDeletion: .detach)
        var catalog = EntityAssociationCatalog<AssociationState>()
        try catalog.register(parentChildren)
        try catalog.register(childGrandchildren)
        let session = EntityEditSession(state: state, associations: catalog)

        #expect(throws: EntityEditDefinitionError.nestedAssociationDeletionUnsupported) {
            try session.deleteParent(parent.id, from: \AssociationState.parents)
        }
    }

    @Test("a competing move rejects even when it reached the proposed destination")
    func competingMoveRejects() throws {
        let first = AssociationParent(id: UUID(), name: "First")
        let second = AssociationParent(id: UUID(), name: "Second")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: first.id, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([first, second]), children: EntityStore([child]))
        let association = try primaryAssociation(removal: .delete, parentDeletion: .delete)
        let session = try editSession(state: state, associations: [association])
        try session.reparent(child.id, from: first.id, to: second.id, through: association)
        state.children.modify(child.id) { $0.primaryParentID = second.id }

        let result = session.apply(to: &state)
        #expect(result.conflicts.first?.kind == .associationChanged)
        #expect(session.apply(to: &state).conflicts.first?.kind == .associationChanged)
        #expect(state.children[child.id]?.primaryParentID == second.id)
    }

    @Test("observed deletion rejects a stale remove")
    func observedDeletionRejects() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: parent.id, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([parent]), children: EntityStore([child]))
        let association = try primaryAssociation(removal: .delete, parentDeletion: .delete)
        let session = try editSession(state: state, associations: [association])
        try session.remove(child.id, from: parent.id, through: association)
        state.children[child.id] = nil

        #expect(session.apply(to: &state).conflicts.first?.kind == .missingEntity)
    }

    @Test("parent deletion applies every named association without touching unrelated children")
    func parentDeleteUsesNamedCurrentGraph() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let otherParent = AssociationParent(id: UUID(), name: "Other")
        let primary = AssociationChild(id: UUID(), name: "Primary", primaryParentID: parent.id, secondaryParentID: nil)
        let secondary = AssociationChild(
            id: UUID(), name: "Secondary", primaryParentID: nil, secondaryParentID: parent.id)
        let unrelated = AssociationChild(
            id: UUID(), name: "Unrelated", primaryParentID: otherParent.id, secondaryParentID: nil)
        var state = AssociationState(
            parents: EntityStore([parent, otherParent]), children: EntityStore([primary, secondary, unrelated]))
        let primaryAssociation = try primaryAssociation(removal: .detach, parentDeletion: .delete)
        let secondaryAssociation = try secondaryAssociation(removal: .delete, parentDeletion: .detach)
        let session = try editSession(state: state, associations: [primaryAssociation, secondaryAssociation])
        try session.deleteParent(parent.id, from: \AssociationState.parents)

        #expect(session.apply(to: &state).wasApplied)
        #expect(state.parents[parent.id] == nil)
        #expect(state.children[primary.id] == nil)
        #expect(state.children[secondary.id]?.secondaryParentID == nil)
        #expect(state.children[unrelated.id] == unrelated)
    }

    @Test("a changed child rejects stale parent deletion without undoing its move")
    func staleParentDeleteRejectsChangedGraph() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let destination = AssociationParent(id: UUID(), name: "Destination")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: parent.id, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([parent, destination]), children: EntityStore([child]))
        let association = try primaryAssociation(removal: .delete, parentDeletion: .delete)
        let session = try editSession(state: state, associations: [association])
        try session.deleteParent(parent.id, from: \AssociationState.parents)
        state.children.modify(child.id) {
            $0.name = "Current child"
            $0.primaryParentID = destination.id
        }

        let result = session.apply(to: &state)
        #expect(result.conflicts.first?.kind == .associationChanged)
        #expect(state.parents[parent.id] == parent)
        #expect(state.children[child.id]?.primaryParentID == destination.id)
        #expect(state.children[child.id]?.name == "Current child")
    }

    @Test("detach on parent deletion preserves a newer child field")
    func parentDetachMergesChildFieldEdit() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: parent.id, secondaryParentID: nil)
        var state = AssociationState(parents: EntityStore([parent]), children: EntityStore([child]))
        let association = try primaryAssociation(removal: .detach, parentDeletion: .detach)
        let session = try editSession(state: state, associations: [association])
        try session.deleteParent(parent.id, from: \AssociationState.parents)
        state.children.modify(child.id) { $0.name = "Current child" }

        #expect(session.apply(to: &state).wasApplied)
        #expect(state.children[child.id]?.name == "Current child")
        #expect(state.children[child.id]?.primaryParentID == nil)
    }

    @Test("destructive parent deletion rejects overlapping parent or child fields")
    func destructiveParentDeleteRejectsFieldEdits() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: parent.id, secondaryParentID: nil)
        let state = AssociationState(parents: EntityStore([parent]), children: EntityStore([child]))
        let association = try primaryAssociation(removal: .delete, parentDeletion: .delete)

        let childSession = try editSession(state: state, associations: [association])
        try childSession.edit(
            AssociationChild.self, id: child.id, in: \AssociationState.children, field: \AssociationChild.name,
            named: "name", to: "Draft")
        #expect(throws: EntityEditDefinitionError.duplicateOperation) {
            try childSession.deleteParent(parent.id, from: \AssociationState.parents)
        }

        let parentSession = try editSession(state: state, associations: [association])
        try parentSession.edit(
            AssociationParent.self, id: parent.id, in: \AssociationState.parents, field: \AssociationParent.name,
            named: "name", to: "Draft")
        #expect(throws: EntityEditDefinitionError.duplicateOperation) {
            try parentSession.deleteParent(parent.id, from: \AssociationState.parents)
        }
    }

    @Test("restrict inspects the current graph at apply time")
    func restrictChecksCurrentGraph() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        var state = AssociationState(parents: EntityStore([parent]))
        let association = try primaryAssociation(removal: .delete, parentDeletion: .restrict)
        let session = try editSession(state: state, associations: [association])
        try session.deleteParent(parent.id, from: \AssociationState.parents)
        let lateChild = AssociationChild(id: UUID(), name: "Late", primaryParentID: parent.id, secondaryParentID: nil)
        state.children[lateChild.id] = lateChild

        let result = session.apply(to: &state)
        #expect(!result.wasApplied)
        #expect(result.conflicts.first?.kind == .associationChanged)
        #expect(state.parents[parent.id] == parent)
        #expect(state.children[lateChild.id] == lateChild)
    }

    @Test("descriptors support another parent type")
    func multipleParentTypes() throws {
        let parent = OtherParent(id: UUID(), name: "Other")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: parent.id, secondaryParentID: nil)
        let state = AssociationState(otherParents: EntityStore([parent]), children: EntityStore([child]))
        let association = try EntityAssociation<AssociationState, OtherParent, AssociationChild>(
            name: "other-primary", parents: \AssociationState.otherParents, children: \AssociationState.children,
            owner: \AssociationChild.primaryParentID, requiredness: .optional, removal: .detach,
            parentDeletion: .restrict)

        #expect(association.parent(of: child.id, in: state) == parent)
    }

    @Test("the catalog rejects descriptor aliases while retaining separate named owners")
    func catalogRejectsAliases() throws {
        let primary = try primaryAssociation(removal: .detach, parentDeletion: .restrict)
        let secondary = try secondaryAssociation(removal: .detach, parentDeletion: .restrict)
        var catalog = EntityAssociationCatalog<AssociationState>()
        try catalog.register(primary)
        try catalog.register(secondary)

        let duplicateName = try Association(
            name: "primary", parents: \AssociationState.parents, children: \AssociationState.children,
            owner: \AssociationChild.secondaryParentID, requiredness: .optional, removal: .detach,
            parentDeletion: .restrict)
        #expect(throws: EntityAssociationConfigurationError.duplicateAssociationName) {
            try catalog.register(duplicateName)
        }
        let duplicateOwner = try Association(
            name: "alias", parents: \AssociationState.parents, children: \AssociationState.children,
            owner: \AssociationChild.primaryParentID, requiredness: .optional, removal: .detach,
            parentDeletion: .restrict)
        #expect(throws: EntityAssociationConfigurationError.duplicateAssociationOwner) {
            try catalog.register(duplicateOwner)
        }
    }

    @Test("commands reject descriptors with unregistered policies")
    func descriptorPoliciesParticipateInRegistration() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let destination = AssociationParent(id: UUID(), name: "Destination")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: parent.id, secondaryParentID: nil)
        let state = AssociationState(parents: EntityStore([parent, destination]), children: EntityStore([child]))
        let registered = try primaryAssociation(requiredness: .required, removal: .restrict, parentDeletion: .restrict)
        let session = try editSession(state: state, associations: [registered])
        let optionalDetach = try primaryAssociation(
            requiredness: .optional, removal: .detach, parentDeletion: .restrict)
        let deleteOnRemoval = try primaryAssociation(
            requiredness: .required, removal: .delete, parentDeletion: .restrict)
        let deleteOnParentDeletion = try primaryAssociation(
            requiredness: .required, removal: .restrict, parentDeletion: .delete)

        #expect(throws: EntityEditDefinitionError.unregisteredAssociation) {
            try session.remove(child.id, from: parent.id, through: optionalDetach)
        }
        #expect(throws: EntityEditDefinitionError.unregisteredAssociation) {
            try session.remove(child.id, from: parent.id, through: deleteOnRemoval)
        }
        #expect(throws: EntityEditDefinitionError.unregisteredAssociation) {
            try session.reparent(child.id, from: parent.id, to: destination.id, through: deleteOnParentDeletion)
        }
    }

    @Test("destructive parent deletion and another named child command cannot overlap")
    func destructiveCrossAssociationOverlapRejectsInEitherOrder() throws {
        let first = AssociationParent(id: UUID(), name: "First")
        let second = AssociationParent(id: UUID(), name: "Second")
        let destination = AssociationParent(id: UUID(), name: "Destination")
        let child = AssociationChild(
            id: UUID(), name: "Child", primaryParentID: first.id, secondaryParentID: second.id)
        let initial = AssociationState(
            parents: EntityStore([first, second, destination]), children: EntityStore([child]))
        let primary = try primaryAssociation(removal: .delete, parentDeletion: .delete)
        let secondary = try secondaryAssociation(removal: .detach, parentDeletion: .detach)

        var reparentState = initial
        let reparentFirst = try editSession(state: initial, associations: [primary, secondary])
        try reparentFirst.reparent(child.id, from: second.id, to: destination.id, through: secondary)
        #expect(throws: EntityEditDefinitionError.duplicateOperation) {
            try reparentFirst.deleteParent(first.id, from: \AssociationState.parents)
        }
        #expect(reparentFirst.apply(to: &reparentState).wasApplied)
        #expect(reparentState.children[child.id]?.secondaryParentID == destination.id)

        var deletionState = initial
        let deletionFirst = try editSession(state: initial, associations: [primary, secondary])
        try deletionFirst.deleteParent(first.id, from: \AssociationState.parents)
        #expect(throws: EntityEditDefinitionError.duplicateOperation) {
            try deletionFirst.reparent(child.id, from: second.id, to: destination.id, through: secondary)
        }
        #expect(deletionFirst.apply(to: &deletionState).wasApplied)
        #expect(deletionState.parents[first.id] == nil)
        #expect(deletionState.children[child.id] == nil)
    }

    @Test("delete-on-remove and another named child command cannot overlap")
    func destructiveRemovalOverlapRejectsInEitherOrder() throws {
        let first = AssociationParent(id: UUID(), name: "First")
        let second = AssociationParent(id: UUID(), name: "Second")
        let destination = AssociationParent(id: UUID(), name: "Destination")
        let child = AssociationChild(
            id: UUID(), name: "Child", primaryParentID: first.id, secondaryParentID: second.id)
        let initial = AssociationState(
            parents: EntityStore([first, second, destination]), children: EntityStore([child]))
        let primary = try primaryAssociation(removal: .delete, parentDeletion: .restrict)
        let secondary = try secondaryAssociation(removal: .detach, parentDeletion: .restrict)

        var reparentState = initial
        let reparentFirst = try editSession(state: initial, associations: [primary, secondary])
        try reparentFirst.reparent(child.id, from: second.id, to: destination.id, through: secondary)
        #expect(throws: EntityEditDefinitionError.duplicateOperation) {
            try reparentFirst.remove(child.id, from: first.id, through: primary)
        }
        #expect(reparentFirst.apply(to: &reparentState).wasApplied)
        #expect(reparentState.children[child.id]?.secondaryParentID == destination.id)

        var deletionState = initial
        let deletionFirst = try editSession(state: initial, associations: [primary, secondary])
        try deletionFirst.remove(child.id, from: first.id, through: primary)
        #expect(throws: EntityEditDefinitionError.duplicateOperation) {
            try deletionFirst.reparent(child.id, from: second.id, to: destination.id, through: secondary)
        }
        #expect(deletionFirst.apply(to: &deletionState).wasApplied)
        #expect(deletionState.children[child.id] == nil)
    }

    @Test("non-destructive commands through separate named associations can share a child")
    func independentNamedAssociationCommandsApplyTogether() throws {
        let first = AssociationParent(id: UUID(), name: "First")
        let second = AssociationParent(id: UUID(), name: "Second")
        let primaryDestination = AssociationParent(id: UUID(), name: "Primary destination")
        let secondaryDestination = AssociationParent(id: UUID(), name: "Secondary destination")
        let child = AssociationChild(
            id: UUID(), name: "Child", primaryParentID: first.id, secondaryParentID: second.id)
        var state = AssociationState(
            parents: EntityStore([first, second, primaryDestination, secondaryDestination]),
            children: EntityStore([child]))
        let primary = try primaryAssociation(removal: .detach, parentDeletion: .restrict)
        let secondary = try secondaryAssociation(removal: .detach, parentDeletion: .restrict)
        let session = try editSession(state: state, associations: [primary, secondary])

        try session.reparent(child.id, from: first.id, to: primaryDestination.id, through: primary)
        try session.reparent(child.id, from: second.id, to: secondaryDestination.id, through: secondary)

        #expect(session.apply(to: &state).wasApplied)
        #expect(state.children[child.id]?.primaryParentID == primaryDestination.id)
        #expect(state.children[child.id]?.secondaryParentID == secondaryDestination.id)
    }

    @Test("generic field edits cannot bypass a registered association owner")
    func ownerFieldRequiresAssociationOperation() throws {
        let parent = AssociationParent(id: UUID(), name: "Parent")
        let child = AssociationChild(id: UUID(), name: "Child", primaryParentID: parent.id, secondaryParentID: nil)
        let state = AssociationState(parents: EntityStore([parent]), children: EntityStore([child]))
        let association = try primaryAssociation(requiredness: .required, removal: .delete, parentDeletion: .delete)
        let session = try editSession(state: state, associations: [association])

        #expect(throws: EntityEditDefinitionError.associationOwnerMutation) {
            try session.edit(
                AssociationChild.self, id: child.id, in: \AssociationState.children,
                field: \AssociationChild.primaryParentID, named: "primaryParentID", to: nil)
        }
    }

    private func primaryAssociation(
        requiredness: EntityAssociationRequiredness = .optional, removal: EntityAssociationPolicy,
        parentDeletion: EntityAssociationPolicy
    ) throws -> Association {
        try Association(
            name: "primary", parents: \AssociationState.parents, children: \AssociationState.children,
            owner: \AssociationChild.primaryParentID, requiredness: requiredness, removal: removal,
            parentDeletion: parentDeletion)
    }

    private func secondaryAssociation(
        removal: EntityAssociationPolicy, parentDeletion: EntityAssociationPolicy
    ) throws -> Association {
        try Association(
            name: "secondary", parents: \AssociationState.parents, children: \AssociationState.children,
            owner: \AssociationChild.secondaryParentID, requiredness: .optional, removal: removal,
            parentDeletion: parentDeletion)
    }

    private func editSession(
        state: AssociationState, associations: [Association]
    ) throws -> EntityEditSession<AssociationState> {
        var catalog = EntityAssociationCatalog<AssociationState>()
        for association in associations {
            try catalog.register(association)
        }
        return EntityEditSession(state: state, associations: catalog)
    }
}
