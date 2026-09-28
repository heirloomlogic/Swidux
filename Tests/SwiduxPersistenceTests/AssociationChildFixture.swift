import Foundation
import SwiduxPersistence

@Persisted
struct AssociationChild: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String = ""
    @BelongsTo(AssociationParent.self, inverse: "childIDs") var ownerID: UUID?
    @BelongsTo(AssociationParent.self, inverse: "reviewIDs") var reviewerID: UUID?
}
