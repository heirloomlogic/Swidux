import Foundation
import SwiduxPersistence

@Persisted
struct AssociationParent: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String = ""
    @HasMany(AssociationChild.self, inverse: "ownerID") var childIDs: [UUID] = []
    @HasMany(AssociationChild.self, inverse: "reviewerID") var reviewIDs: [UUID] = []
}
