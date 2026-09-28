import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

@MainActor
@Suite("Association review regressions")
struct AssociationRegressionTests {
    @Test("parent detachment requires registration of the scalar child store")
    func detachRegistration() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [TagModel.self, ScalarOwnedModel.self])
        let parent = Tag(id: UUID(), label: "Parent")
        let child = ScalarOwned(id: UUID(), ownerID: parent.id)
        let db = EntityDB(modelContainer: container)
        try await db.upsert(parent, as: TagModel.self)
        try await db.upsert(child, as: ScalarOwnedModel.self)
        var state = ScalarAssociationState(parents: EntityStore([parent]), children: EntityStore([child]))
        let edge = try EntityAssociation(
            name: "children", parents: \ScalarAssociationState.parents, children: \ScalarAssociationState.children,
            owner: \ScalarOwned.ownerID, requiredness: .optional, removal: .detach, parentDeletion: .detach)
        var catalog = EntityAssociationCatalog<ScalarAssociationState>()
        try catalog.register(edge)
        let deletion = EntityEditSession(state: state, associations: catalog)
        try deletion.deleteParent(parent.id, from: \ScalarAssociationState.parents)
        let writer = try EntityEditPersistence<ScalarAssociationState>(
            container: container, entities: [.entity(\.parents)])
        #expect(throws: EntityEditPersistenceError.unregisteredStore) { try writer.commit(deletion, to: &state) }
        #expect(state.parents[parent.id] == parent)
        #expect(state.children[child.id] == child)
        #expect(try await db.fetchAll(TagModel.self) == [parent])
        #expect(try await db.fetchAll(ScalarOwnedModel.self) == [child])
        let completeWriter = try EntityEditPersistence<ScalarAssociationState>(
            container: container, entities: [.entity(\.parents), .entity(\.children)])
        #expect(try completeWriter.commit(deletion, to: &state).wasApplied)
        #expect(try await db.fetchAll(ScalarOwnedModel.self).first?.ownerID == nil)
        #expect(try completeWriter.undo(#require(deletion.undoReceipt), in: &state).wasApplied)
        #expect(try await db.fetchAll(ScalarOwnedModel.self) == [child])
    }

    @Test("grouped commit during a coordinator read preserves the committed canonical value", arguments: [false, true])
    func groupedCommitDuringRead(partial: Bool) async throws {
        let container = try makeTaggedContainer()
        let coordinator = try makeTaggedCoordinator(container: container)
        let note = Note(id: UUID(), title: "Old", pinned: false)
        try await coordinator.database.upsert(note, as: NoteModel.self)
        let store = makeTaggedStore(coordinator)
        await coordinator.hydrate(into: store)
        let writer = try EntityEditPersistence<TaggedState>(container: container, entities: [.entity(\.notes)])
        coordinator.duringReadPhase = {
            coordinator.duringReadPhase = nil
            store.mutate { state in
                do {
                    let session = EntityEditSession(state: state)
                    try session.edit(
                        Note.self, id: note.id, in: \TaggedState.notes, field: \Note.title, named: "title",
                        to: "Committed")
                    #expect(try writer.commit(session, to: &state).wasApplied)
                } catch { Issue.record(error) }
            }
        }
        if partial {
            await coordinator.mergeRemote(into: store, ids: [note.id])
        } else {
            await coordinator.rehydrate(into: store)
        }
        coordinator.duringReadPhase = nil
        #expect(store.notes[note.id]?.title == "Committed")
        #expect(try await coordinator.database.fetchAll(NoteModel.self).first?.title == "Committed")
    }

    @Test("own deletion history does not prevent restoration of a local deletion")
    func ownDeletionHistory() async throws {
        let coordinator = try makeNotesCoordinator()
        let note = Note(id: UUID(), title: "Local", pinned: false)
        let store = makeNotesStore(coordinator)
        store.send(.add(note))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)
        let before = store.notes
        store.send(.remove(note.id))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)
        #expect(!store.notes.remotelyRemovedIDs.contains(note.id))
        store.mutate { $0.notes.restore(from: before) }
        #expect(store.notes[note.id] == note)
    }

    @Test("duplicate collapse rejects deletion of a referenced parent and rolls back")
    func collapseReferencedParent() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [
            AssociationParentModel.self, AssociationChildModel.self,
        ])
        let db = EntityDB(modelContainer: container)
        let parent = AssociationParent(id: UUID())
        let child = AssociationChild(id: UUID(), ownerID: parent.id, reviewerID: nil)
        var seed = EntityPersistenceGroup()
        try seed.change(from: Optional<AssociationParent>.none, to: parent)
        try seed.change(from: Optional<AssociationChild>.none, to: child)
        try await db.apply(seed)
        await #expect(throws: SwiduxAssociationError.self) {
            try await db.collapseDuplicates(as: AssociationParentModel.self) { _ in [] }
        }
        #expect(try await db.fetchAll(AssociationParentModel.self) == [parent])
        #expect(
            try ModelContext(container).fetch(FetchDescriptor<AssociationChildModel>()).first?._swidux_ownerIDReference?
                .id == parent.id)
    }

    @Test("duplicate collapse reconciles a surviving child's changed scalar owner")
    func collapseOwnerChange() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [
            AssociationParentModel.self, AssociationChildModel.self,
        ])
        let db = EntityDB(modelContainer: container)
        let first = AssociationParent(id: UUID())
        let second = AssociationParent(id: UUID())
        let child = AssociationChild(id: UUID(), ownerID: first.id, reviewerID: nil)
        var seed = EntityPersistenceGroup()
        try seed.change(from: Optional<AssociationParent>.none, to: first)
        try seed.change(from: Optional<AssociationParent>.none, to: second)
        try seed.change(from: Optional<AssociationChild>.none, to: child)
        try await db.apply(seed)
        try await db.collapseDuplicates(as: AssociationChildModel.self) { rows in
            rows.map { row in
                var result = row
                result.ownerID = second.id
                return result
            }
        }
        let saved = try #require(ModelContext(container).fetch(FetchDescriptor<AssociationChildModel>()).first)
        #expect(saved.ownerID == second.id)
        #expect(saved._swidux_ownerIDReference?.id == second.id)
    }
    @Test(
        "grouped deletion history permits its own undo but rejects a later foreign tombstone", arguments: [false, true])
    func groupedDeletionHistory(foreignDeletion: Bool) async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [TagModel.self, ScalarOwnedModel.self])
        let coordinator = PersistenceCoordinator<ScalarAssociationState, Int>(
            entities: [.entity(\.parents), .entity(\.children)], container: container)
        let parent = Tag(id: UUID(), label: "Parent")
        let child = ScalarOwned(id: UUID(), ownerID: parent.id)
        try await coordinator.database.upsert(parent, as: TagModel.self)
        try await coordinator.database.upsert(child, as: ScalarOwnedModel.self)
        let store = Store<ScalarAssociationState, Int>(initialState: ScalarAssociationState(), reducer: { _, _ in nil })
        await coordinator.hydrate(into: store)
        let edge = try EntityAssociation(
            name: "children", parents: \ScalarAssociationState.parents, children: \ScalarAssociationState.children,
            owner: \ScalarOwned.ownerID, requiredness: .optional, removal: .delete, parentDeletion: .delete)
        var catalog = EntityAssociationCatalog<ScalarAssociationState>()
        try catalog.register(edge)
        let deletion = EntityEditSession(state: ScalarAssociationState(observer: store.observer), associations: catalog)
        try deletion.remove(child.id, from: parent.id, through: edge)
        let writer = try EntityEditPersistence<ScalarAssociationState>(
            container: container, entities: [.entity(\.parents), .entity(\.children)])
        store.mutate { state in
            do { #expect(try writer.commit(deletion, to: &state).wasApplied) } catch { Issue.record(error) }
        }
        if foreignDeletion {
            let context = ModelContext(container)
            let row = try ScalarOwnedModel(from: child)
            context.insert(row)
            try context.save()
            context.delete(row)
            try context.save()
        }
        await coordinator.mergeChanges(into: store)
        #expect(store.children.remotelyRemovedIDs.contains(child.id) == foreignDeletion)
        let receipt = try #require(deletion.undoReceipt)
        store.mutate { state in
            do { #expect(try writer.undo(receipt, in: &state).wasApplied == !foreignDeletion) } catch {
                Issue.record(error)
            }
        }
        #expect(store.children[child.id] == (foreignDeletion ? nil : child))
    }
}
