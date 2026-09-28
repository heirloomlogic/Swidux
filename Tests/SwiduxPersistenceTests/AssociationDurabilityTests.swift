import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

private struct AssociationState: Sendable {
    var parents = EntityStore<AssociationParent>()
    var children = EntityStore<AssociationChild>()
}

@MainActor
@Suite("Association durability")
struct AssociationDurabilityTests {
    @Test("fresh stores preserve row identity, direct edits, grouped undo, and exact reordered IDs on reopen")
    func diskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("associations.store")
        let parentID = UUID()
        let childIDs = (0..<12).map { _ in UUID() }
        let unresolved = UUID()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func write() throws -> Data {
            let container = try ContainerFactory.makeLocalContainer(
                models: [AssociationParentModel.self, AssociationChildModel.self], url: url)
            let parent = AssociationParent(id: parentID, title: "Original", childIDs: childIDs)
            let children = childIDs.map { AssociationChild(id: $0, title: "Old", ownerID: parentID, reviewerID: nil) }
            var seed = EntityPersistenceGroup()
            try seed.change(from: Optional<AssociationParent>.none, to: parent)
            for child in children.dropFirst() { try seed.change(from: Optional<AssociationChild>.none, to: child) }
            try seed.apply(in: ModelContext(container))
            var state = AssociationState(
                parents: EntityStore([parent]), children: EntityStore(Array(children.dropFirst())))
            let association = try EntityAssociation(
                name: "children", parents: \AssociationState.parents,
                children: \AssociationState.children, owner: \AssociationChild.ownerID,
                order: \AssociationParent.childIDs,
                requiredness: .optional, removal: .delete, parentDeletion: .delete)
            var catalog = EntityAssociationCatalog<AssociationState>()
            try catalog.register(association)
            let parentSession = EntityEditSession(state: state, associations: catalog)
            try parentSession.edit(
                AssociationParent.self, id: parentID, in: \AssociationState.parents,
                field: \AssociationParent.title, named: "title", to: "Renamed")
            let writer = try EntityEditPersistence<AssociationState>(
                container: container, entities: [.entity(\.parents), .entity(\.children)])
            let creation = EntityEditSession(state: state, associations: catalog)
            try creation.create(children[0], for: parentID, through: association)
            #expect(try writer.commit(creation, to: &state).wasApplied)
            let before = ModelContext(container)
            let persistentID = try #require(
                before.fetch(AssociationChildModel.swiduxBatchFetchDescriptor(ids: [childIDs[0]])).first?
                    .persistentModelID)
            let childSession = EntityEditSession(state: state, associations: catalog)
            try childSession.edit(
                AssociationChild.self, id: childIDs[0], in: \AssociationState.children,
                field: \AssociationChild.title, named: "title", to: "New")
            #expect(try writer.commit(childSession, to: &state).wasApplied)
            #expect(try writer.commit(parentSession, to: &state).wasApplied)
            #expect(state.children[childIDs[0]]?.title == "New")
            let reorder = EntityEditSession(state: state, associations: catalog)
            try reorder.reorder(childIDs.reversed() + [unresolved], for: parentID, through: association)
            #expect(try writer.commit(reorder, to: &state).wasApplied)
            let remove = EntityEditSession(state: state, associations: catalog)
            try remove.remove(childIDs[1], from: parentID, through: association)
            #expect(try writer.commit(remove, to: &state).wasApplied)
            #expect(try writer.undo(#require(remove.undoReceipt), in: &state).wasApplied)
            let after = ModelContext(container)
            let finalID = try #require(
                after.fetch(AssociationChildModel.swiduxBatchFetchDescriptor(ids: [childIDs[0]])).first?
                    .persistentModelID)
            #expect(finalID == persistentID)
            return try encoder.encode(persistentID)
        }
        let persistedIdentity = try write()
        let reopened = try ContainerFactory.makeLocalContainer(
            models: [AssociationParentModel.self, AssociationChildModel.self], url: url)
        let context = ModelContext(reopened)
        let parent = try #require(context.fetch(FetchDescriptor<AssociationParentModel>()).first)
        #expect(parent.title == "Renamed")
        #expect(parent.childIDs == childIDs.reversed() + [unresolved])
        let children = try context.fetch(FetchDescriptor<AssociationChildModel>())
        #expect(children.count == 12)
        #expect(children.first { $0.id == childIDs[0] }?.title == "New")
        let reopenedID = try #require(children.first { $0.id == childIDs[0] }?.persistentModelID)
        let reopenedData = try encoder.encode(reopenedID)
        #expect(reopenedData == persistedIdentity)
        #expect(children.allSatisfy { $0._swidux_ownerIDReference?.id == parentID })
    }

    @Test("unresolved owners remain scalar identities and resolve on a later parent arrival")
    func partialArrival() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [
            AssociationParentModel.self, AssociationChildModel.self,
        ])
        let db = EntityDB(modelContainer: container)
        let owner = AssociationParent(id: UUID())
        let child = AssociationChild(id: UUID(), ownerID: owner.id, reviewerID: nil)
        try await db.upsert(child, as: AssociationChildModel.self)
        let context = ModelContext(container)
        let unresolved = try #require(context.fetch(FetchDescriptor<AssociationChildModel>()).first)
        #expect(unresolved.ownerID == owner.id)
        #expect(unresolved._swidux_ownerIDReference == nil)
        try await db.upsert(owner, as: AssociationParentModel.self)
        let fresh = ModelContext(container)
        #expect(
            try fresh.fetch(FetchDescriptor<AssociationChildModel>()).first?._swidux_ownerIDReference?.id == owner.id)
    }

    @Test("deleting a still referenced parent rejects the transaction")
    func danglingDeletion() async throws {
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
        var deletion = EntityPersistenceGroup()
        try deletion.change(from: parent, to: nil)
        await #expect(throws: SwiduxAssociationError.self) { try await db.apply(deletion) }
        #expect(try await db.fetchAll(AssociationParentModel.self) == [parent])
    }
    @Test("a parent deleted on disk before a move rejects the durable session")
    func deletedDestination() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [
            AssociationParentModel.self, AssociationChildModel.self,
        ])
        let first = AssociationParent(id: UUID())
        let second = AssociationParent(id: UUID())
        let child = AssociationChild(id: UUID(), ownerID: first.id, reviewerID: nil)
        var seed = EntityPersistenceGroup()
        try seed.change(from: Optional<AssociationParent>.none, to: first)
        try seed.change(from: Optional<AssociationParent>.none, to: second)
        try seed.change(from: Optional<AssociationChild>.none, to: child)
        let db = EntityDB(modelContainer: container)
        try await db.apply(seed)
        var state = AssociationState(parents: EntityStore([first, second]), children: EntityStore([child]))
        let edge = try EntityAssociation(
            name: "children", parents: \AssociationState.parents, children: \AssociationState.children,
            owner: \AssociationChild.ownerID, requiredness: .optional, removal: .detach, parentDeletion: .detach)
        var catalog = EntityAssociationCatalog<AssociationState>()
        try catalog.register(edge)
        let session = EntityEditSession(state: state, associations: catalog)
        try session.reparent(child.id, from: first.id, to: second.id, through: edge)
        var deletion = EntityPersistenceGroup()
        try deletion.change(from: second, to: nil)
        try await db.apply(deletion)
        let writer = try EntityEditPersistence<AssociationState>(
            container: container, entities: [.entity(\.parents), .entity(\.children)])
        #expect(throws: EntityPersistenceConflict.self) { try writer.commit(session, to: &state) }
        #expect(state.children[child.id]?.ownerID == first.id)
    }
}
