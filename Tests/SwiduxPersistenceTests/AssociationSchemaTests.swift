import Foundation
import SwiftData
import Testing

@testable import SwiduxPersistence

@Suite("Generated scalar association schema")
struct AssociationSchemaTests {
    @Test("cross-file named edges generate optional nullify inverses")
    func reciprocalSchema() throws {
        let schema = Schema([AssociationParentModel.self, AssociationChildModel.self])
        let relationships = schema.entities.flatMap(\.relationships)
        #expect(relationships.count == 4)
        #expect(relationships.allSatisfy { $0.isOptional })
        #expect(relationships.allSatisfy { $0.deleteRule == .nullify })
        #expect(CloudKitIncompatibleSchema.oneSidedRelationships(in: schema).isEmpty)
        #expect(
            AssociationParent.swiduxAssociationInverse("childIDs") == \AssociationParentModel._swidux_childIDsReference)
        #expect(
            AssociationParent.swiduxAssociationInverse("reviewIDs")
                == \AssociationParentModel._swidux_reviewIDsReference)
        #expect(AssociationParent.swiduxAssociationInverse("unknown") == nil)
    }

    @Test("scalar ordering survives storage while named memberships remain separate")
    func orderedScalarRoundTrip() throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [
            AssociationParentModel.self, AssociationChildModel.self,
        ])
        let context = ModelContext(container)
        let firstID = UUID()
        let secondID = UUID()
        let owner = AssociationParent(id: UUID(), childIDs: [secondID, firstID])
        let reviewer = AssociationParent(id: UUID(), reviewIDs: [firstID])
        let first = AssociationChild(id: firstID, ownerID: owner.id, reviewerID: reviewer.id)
        let second = AssociationChild(id: secondID, ownerID: owner.id, reviewerID: nil)
        let ownerModel = try AssociationParentModel(from: owner)
        let reviewerModel = try AssociationParentModel(from: reviewer)
        let firstModel = try AssociationChildModel(from: first)
        let secondModel = try AssociationChildModel(from: second)
        context.insert(ownerModel)
        context.insert(reviewerModel)
        context.insert(firstModel)
        context.insert(secondModel)
        try SwiduxAssociationGraph.reconcile(models: [AssociationParentModel.self], in: context)
        try context.save()
        #expect(firstModel._swidux_ownerIDReference?.id == owner.id)
        #expect(firstModel._swidux_reviewerIDReference?.id == reviewer.id)
        #expect(Set(ownerModel._swidux_childIDsReference?.map(\.id) ?? []) == [firstID, secondID])
        #expect(reviewerModel._swidux_reviewIDsReference?.map(\.id) == [firstID])
        let fresh = ModelContext(container)
        let loaded = try fresh.fetch(FetchDescriptor<AssociationParentModel>()).first { $0.id == owner.id }
        #expect(try loaded?.toDomain() == owner)
    }

    @Test("scalar ownership wins over a divergent storage reference and grouped writes repair it")
    func scalarOwnershipRepairsReferences() throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [
            AssociationParentModel.self, AssociationChildModel.self,
        ])
        let owner = AssociationParent(id: UUID())
        let wrongOwner = AssociationParent(id: UUID())
        let child = AssociationChild(id: UUID(), ownerID: owner.id, reviewerID: nil)
        var initial = EntityPersistenceGroup()
        try initial.change(from: Optional<AssociationParent>.none, to: owner)
        try initial.change(from: Optional<AssociationParent>.none, to: wrongOwner)
        try initial.change(from: Optional<AssociationChild>.none, to: child)
        try initial.apply(in: ModelContext(container))

        let raw = ModelContext(container)
        let childModel = try #require(raw.fetch(FetchDescriptor<AssociationChildModel>()).first)
        let wrongOwnerModel = try #require(
            raw.fetch(FetchDescriptor<AssociationParentModel>()).first { $0.id == wrongOwner.id })
        childModel._swidux_ownerIDReference = wrongOwnerModel
        try raw.save()
        #expect(childModel._swidux_ownerIDReference?.id == wrongOwner.id)
        #expect(childModel.ownerID == owner.id)
        #expect(try childModel.toDomain() == child)

        var repair = EntityPersistenceGroup()
        try repair.change(from: child, to: child)
        try repair.apply(in: ModelContext(container))
        let fresh = ModelContext(container)
        let repaired = try #require(fresh.fetch(FetchDescriptor<AssociationChildModel>()).first)
        #expect(repaired._swidux_ownerIDReference?.id == owner.id)
        #expect(try repaired.toDomain() == child)
    }

    @Test("a named edge cannot point at a different reciprocal endpoint")
    func malformedReciprocalDescriptor() throws {
        let descriptor = SwiduxAssociationDescriptor<AssociationChildModel>.belongsTo(
            property: "ownerID", inverse: "reviewIDs", destination: AssociationParent.self,
            id: \AssociationChildModel.ownerID, reference: \AssociationChildModel._swidux_ownerIDReference)
        #expect(
            throws: SwiduxAssociationError.invalidInverse(
                entity: String(reflecting: AssociationChildModel.self), property: "ownerID")
        ) {
            try descriptor.validate()
        }
    }

    @Test("generated inverses do not claim unverified CloudKit synchronization")
    func mirroredContainerIsGated() throws {
        #expect(throws: SwiduxAssociationError.synchronizationUnavailable) {
            try ContainerFactory.makeContainer(
                models: [AssociationParentModel.self, AssociationChildModel.self],
                cloudKitDatabase: .private("iCloud.com.heirloomlogic.swidux.associationcheck"), inMemory: true)
        }
    }
}
