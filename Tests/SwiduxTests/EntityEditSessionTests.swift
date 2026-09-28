import Foundation
import Testing

@testable import Swidux

private struct EditParent: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var note: String?
}

private struct EditChild: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var count: Int
}

private struct EditState: Equatable, Sendable {
    var parents = EntityStore<EditParent>()
    var children = EntityStore<EditChild>()
}

@MainActor
@Suite("Entity editing sessions")
struct EntityEditSessionTests {
    @Test("different fields merge against current canonical values")
    func nonconflictingFieldsMerge() throws {
        let parent = EditParent(id: UUID(), title: "Original", note: "Original note")
        let child = EditChild(id: UUID(), title: "Child", count: 1)
        var state = EditState(parents: EntityStore([parent]), children: EntityStore([child]))
        let session = EntityEditSession(state: state)

        try session.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title",
            to: "Draft")
        try session.edit(
            EditChild.self, id: child.id, in: \EditState.children, field: \EditChild.count, named: "count", to: 2)
        state.parents.modify(parent.id) { $0.note = "Current note" }
        state.children.modify(child.id) { $0.title = "Current child" }

        #expect(session.apply(to: &state).wasApplied)
        #expect(state.parents[parent.id] == EditParent(id: parent.id, title: "Draft", note: "Current note"))
        #expect(state.children[child.id] == EditChild(id: child.id, title: "Current child", count: 2))
    }

    @Test("equal current and proposed values are already satisfied")
    func equalOutcomeSucceeds() throws {
        let parent = EditParent(id: UUID(), title: "Original", note: nil)
        var state = EditState(parents: EntityStore([parent]))
        let session = EntityEditSession(state: state)
        try session.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title", to: "Same"
        )
        state.parents.modify(parent.id) { $0.title = "Same" }

        #expect(session.apply(to: &state).wasApplied)
        #expect(state.parents[parent.id]?.title == "Same")
    }

    @Test("a parent-only edit leaves a newer child value untouched")
    func parentOnlyEditPreservesDirectChildEdit() throws {
        let parent = EditParent(id: UUID(), title: "Original", note: nil)
        let child = EditChild(id: UUID(), title: "Original child", count: 1)
        var state = EditState(parents: EntityStore([parent]), children: EntityStore([child]))
        let session = EntityEditSession(state: state)
        try session.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title",
            to: "Draft parent")
        state.children.modify(child.id) { $0.title = "Direct child edit" }

        #expect(session.apply(to: &state).wasApplied)
        #expect(state.parents[parent.id]?.title == "Draft parent")
        #expect(state.children[child.id]?.title == "Direct child edit")
    }

    @Test("a field reverted to its baseline emits no write")
    func revertedFieldIsUnchanged() throws {
        let parent = EditParent(id: UUID(), title: "Original", note: nil)
        var state = EditState(parents: EntityStore([parent]))
        let session = EntityEditSession(state: state)
        try session.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title",
            to: "Draft")
        try session.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title",
            to: "Original")
        state.parents.modify(parent.id) { $0.title = "Current" }

        #expect(session.apply(to: &state).wasApplied)
        #expect(state.parents[parent.id]?.title == "Current")
    }

    @Test("all field conflicts reject the group and retain its complete draft")
    func conflictsRejectAtomicallyAndPreserveDraft() throws {
        let parent = EditParent(id: UUID(), title: "Original", note: "Original note")
        let child = EditChild(id: UUID(), title: "Child", count: 1)
        var state = EditState(parents: EntityStore([parent]), children: EntityStore([child]))
        let session = EntityEditSession(state: state)
        try session.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title",
            to: "Draft")
        try session.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.note, named: "note",
            to: "Draft note")
        try session.edit(
            EditChild.self, id: child.id, in: \EditState.children, field: \EditChild.count, named: "count", to: 2)
        state.parents.modify(parent.id) {
            $0.title = "Current"
            $0.note = "Current note"
        }

        let result = session.apply(to: &state)
        #expect(!result.wasApplied)
        #expect(result.conflicts.map(\.field) == ["note", "title"])
        #expect(result.conflicts[0].original?.value(as: String?.self) == "Original note")
        #expect(result.conflicts[0].current?.value(as: String?.self) == "Current note")
        #expect(result.conflicts[0].proposed?.value(as: String?.self) == "Draft note")
        #expect(result.conflicts[1].entity.id == parent.id)
        #expect(result.conflicts[1].entity.type == ObjectIdentifier(EditParent.self))
        #expect(result.conflicts[1].original?.value(as: String.self) == "Original")
        #expect(result.conflicts[1].current?.value(as: String.self) == "Current")
        #expect(result.conflicts[1].proposed?.value(as: String.self) == "Draft")
        #expect(state.children[child.id]?.count == 1)
        #expect(session.draft(EditParent.self, id: parent.id, in: \EditState.parents)?.title == "Draft")
        #expect(session.draft(EditChild.self, id: child.id, in: \EditState.children)?.count == 2)

        let retry = session.apply(to: &state)
        #expect(retry.conflicts.map(\.field) == ["note", "title"])
        #expect(session.draft(EditChild.self, id: child.id, in: \EditState.children)?.count == 2)
    }

    @Test("a missing entity is distinct from a nil current field value")
    func missingEntityIsDistinctFromNil() throws {
        let parent = EditParent(id: UUID(), title: "Original", note: "Original note")
        var nilState = EditState(parents: EntityStore([parent]))
        let nilSession = EntityEditSession(state: nilState)
        try nilSession.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.note, named: "note", to: "Draft")
        nilState.parents.modify(parent.id) { $0.note = nil }

        let nilResult = nilSession.apply(to: &nilState)
        #expect(nilResult.conflicts.first?.kind == .fieldChanged)
        #expect(nilResult.conflicts.first?.current?.value(as: String?.self) == .some(nil))

        var missingState = EditState(parents: EntityStore([parent]))
        let missingSession = EntityEditSession(state: missingState)
        try missingSession.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title",
            to: "Draft")
        missingState.parents[parent.id] = nil

        let missingResult = missingSession.apply(to: &missingState)
        #expect(missingResult.conflicts.first?.kind == .missingEntity)
        #expect(missingResult.conflicts.first?.current == nil)
    }

    @Test("cancellation and successful apply make a session terminal")
    func terminalSessionStatesRejectReuse() throws {
        let parent = EditParent(id: UUID(), title: "Original", note: nil)
        var state = EditState(parents: EntityStore([parent]))
        let cancelled = EntityEditSession(state: state)
        try cancelled.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title",
            to: "Draft")
        cancelled.cancel()
        #expect(cancelled.draft(EditParent.self, id: parent.id, in: \EditState.parents) == nil)
        #expect(cancelled.apply(to: &state).conflicts.first?.kind == .cancelledSession)

        let applied = EntityEditSession(state: state)
        try applied.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title",
            to: "Applied")
        #expect(applied.apply(to: &state).wasApplied)
        #expect(applied.apply(to: &state).conflicts.first?.kind == .alreadyApplied)
        #expect(state.parents[parent.id]?.title == "Applied")
    }

    @Test("identity edits and duplicate field aliases are rejected")
    func invalidFieldDefinitionsAreRejected() throws {
        let parent = EditParent(id: UUID(), title: "Original", note: nil)
        let state = EditState(parents: EntityStore([parent]))
        let identitySession = EntityEditSession(state: state)
        #expect(throws: EntityEditDefinitionError.identityMutation) {
            try identitySession.edit(
                EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.id, named: "id", to: UUID())
        }

        let aliasSession = EntityEditSession(state: state)
        try aliasSession.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title",
            to: "First")
        try aliasSession.edit(
            EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "title",
            to: "Latest")
        #expect(aliasSession.draft(EditParent.self, id: parent.id, in: \EditState.parents)?.title == "Latest")
        #expect(throws: EntityEditDefinitionError.duplicateFieldIdentity) {
            try aliasSession.edit(
                EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.title, named: "headline",
                to: "Alias")
        }
        #expect(throws: EntityEditDefinitionError.duplicateFieldIdentity) {
            try aliasSession.edit(
                EditParent.self, id: parent.id, in: \EditState.parents, field: \EditParent.note, named: "title",
                to: "Alias")
        }
    }

    @Test("equal UUIDs in different entity types do not alias")
    func entityTypesParticipateInIdentity() throws {
        let id = UUID()
        let parent = EditParent(id: id, title: "Parent", note: nil)
        let child = EditChild(id: id, title: "Child", count: 1)
        var state = EditState(parents: EntityStore([parent]), children: EntityStore([child]))
        let session = EntityEditSession(state: state)
        try session.edit(
            EditParent.self, id: id, in: \EditState.parents, field: \EditParent.title, named: "title", to: "New parent")
        try session.edit(
            EditChild.self, id: id, in: \EditState.children, field: \EditChild.title, named: "title", to: "New child")

        #expect(session.apply(to: &state).wasApplied)
        #expect(state.parents[id]?.title == "New parent")
        #expect(state.children[id]?.title == "New child")
    }
}
