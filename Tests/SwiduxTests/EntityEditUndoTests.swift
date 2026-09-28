import Foundation
import Testing

@testable import Swidux

private struct UndoParent: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
}
private struct UndoChild: Identifiable, Equatable, Sendable {
    var id: UUID
    var parentID: UUID?
    var title: String
}
private struct UndoState: Sendable {
    var parents: EntityStore<UndoParent>
    var children: EntityStore<UndoChild>
}

@MainActor
@Suite("Guarded edit undo")
struct EntityEditUndoTests {
    private func association() throws -> EntityAssociation<UndoState, UndoParent, UndoChild> {
        try EntityAssociation(
            name: "children", parents: \UndoState.parents, children: \UndoState.children,
            owner: \UndoChild.parentID, requiredness: .optional, removal: .delete, parentDeletion: .delete)
    }

    @Test("undo reparent preserves an unrelated newer title and rejects a competing move")
    func reparent() throws {
        let first = UndoParent(id: UUID(), title: "First")
        let second = UndoParent(id: UUID(), title: "Second")
        let child = UndoChild(id: UUID(), parentID: first.id, title: "Old")
        var state = UndoState(parents: EntityStore([first, second]), children: EntityStore([child]))
        let association = try association()
        var catalog = EntityAssociationCatalog<UndoState>()
        try catalog.register(association)
        let session = EntityEditSession(state: state, associations: catalog)
        try session.reparent(child.id, from: first.id, to: second.id, through: association)
        #expect(session.apply(to: &state).wasApplied)
        let receipt = try #require(session.undoReceipt)
        state.children.modify(child.id) { $0.title = "New" }
        #expect(receipt.undo(in: &state).wasApplied)
        #expect(state.children[child.id]?.parentID == first.id)
        #expect(state.children[child.id]?.title == "New")
        #expect(!receipt.undo(in: &state).wasApplied)
    }

    @Test("undo creation rejects newer fields without deleting the child")
    func creation() throws {
        let parent = UndoParent(id: UUID(), title: "Parent")
        let child = UndoChild(id: UUID(), parentID: nil, title: "Old")
        var state = UndoState(parents: EntityStore([parent]), children: EntityStore())
        let association = try association()
        var catalog = EntityAssociationCatalog<UndoState>()
        try catalog.register(association)
        let session = EntityEditSession(state: state, associations: catalog)
        try session.create(child, for: parent.id, through: association)
        #expect(session.apply(to: &state).wasApplied)
        state.children.modify(child.id) { $0.title = "New" }
        let receipt = try #require(session.undoReceipt)
        #expect(!receipt.undo(in: &state).wasApplied)
        #expect(state.children[child.id]?.title == "New")
    }

    @Test("observed deletion of an already locally deleted row blocks resurrection")
    func deletionEvidence() throws {
        let parent = UndoParent(id: UUID(), title: "Parent")
        let child = UndoChild(id: UUID(), parentID: parent.id, title: "Old")
        var state = UndoState(parents: EntityStore([parent]), children: EntityStore([child]))
        let association = try association()
        var catalog = EntityAssociationCatalog<UndoState>()
        try catalog.register(association)
        let session = EntityEditSession(state: state, associations: catalog)
        try session.deleteParent(parent.id, from: \UndoState.parents)
        #expect(session.apply(to: &state).wasApplied)
        state.parents.resetChanges()
        state.children.resetChanges()
        state.children.reconcile(with: EntityStore(), deleting: [child.id], preserving: [])
        let receipt = try #require(session.undoReceipt)
        #expect(!receipt.undo(in: &state).wasApplied)
        #expect(state.parents[parent.id] == nil)
        #expect(state.children[child.id] == nil)
    }
    @Test("undo detachment restores an optional owner and preserves later child fields")
    func detach() throws {
        let parent = UndoParent(id: UUID(), title: "Parent")
        let child = UndoChild(id: UUID(), parentID: parent.id, title: "Old")
        var state = UndoState(parents: EntityStore([parent]), children: EntityStore([child]))
        let association = try EntityAssociation(
            name: "children", parents: \UndoState.parents, children: \UndoState.children,
            owner: \UndoChild.parentID, requiredness: .optional, removal: .detach, parentDeletion: .detach)
        var catalog = EntityAssociationCatalog<UndoState>()
        try catalog.register(association)
        let session = EntityEditSession(state: state, associations: catalog)
        try session.remove(child.id, from: parent.id, through: association)
        #expect(session.apply(to: &state).wasApplied)
        state.children.modify(child.id) { $0.title = "New" }
        #expect(try #require(session.undoReceipt).undo(in: &state).wasApplied)
        #expect(state.children[child.id]?.parentID == parent.id)
        #expect(state.children[child.id]?.title == "New")
    }

    @Test("a competing owner move rejects the complete undo group")
    func competingMove() throws {
        let first = UndoParent(id: UUID(), title: "First")
        let second = UndoParent(id: UUID(), title: "Second")
        let child = UndoChild(id: UUID(), parentID: first.id, title: "Old")
        var state = UndoState(parents: EntityStore([first, second]), children: EntityStore([child]))
        let association = try association()
        var catalog = EntityAssociationCatalog<UndoState>()
        try catalog.register(association)
        let session = EntityEditSession(state: state, associations: catalog)
        try session.reparent(child.id, from: first.id, to: second.id, through: association)
        try session.edit(
            UndoParent.self, id: first.id, in: \UndoState.parents, field: \UndoParent.title, named: "title",
            to: "Changed")
        #expect(session.apply(to: &state).wasApplied)
        state.children.modify(child.id) { $0.parentID = UUID() }
        #expect(try !#require(session.undoReceipt).undo(in: &state).wasApplied)
        #expect(state.parents[first.id]?.title == "Changed")
    }

    @Test("undo field edits preserves other current fields and refuses a replacement arrival")
    func fieldReplacement() throws {
        let child = UndoChild(id: UUID(), parentID: nil, title: "Old")
        var state = UndoState(parents: EntityStore(), children: EntityStore([child]))
        let session = EntityEditSession(state: state)
        try session.edit(
            UndoChild.self, id: child.id, in: \UndoState.children, field: \UndoChild.title, named: "title", to: "Edited"
        )
        #expect(session.apply(to: &state).wasApplied)
        state.children.resetChanges()
        let replacement = try #require(state.children[child.id])
        state.children.reconcile(with: EntityStore(), deleting: [child.id], preserving: [])
        state.children.reconcile(with: EntityStore([replacement]), preserving: [], removingMissing: false)
        #expect(try !#require(session.undoReceipt).undo(in: &state).wasApplied)
        #expect(state.children[child.id]?.title == "Edited")
    }
}
