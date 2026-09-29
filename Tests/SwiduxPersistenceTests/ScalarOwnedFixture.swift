import Foundation
import Swidux
import SwiduxPersistence

@Persisted
struct ScalarOwned: Identifiable, Equatable, Sendable {
    var id: UUID
    var ownerID: UUID?
}

@Swidux
nonisolated struct ScalarAssociationState: Equatable, Sendable {
    var parents: EntityStore<Tag> = EntityStore()
    var children: EntityStore<ScalarOwned> = EntityStore()
    var books: EntityStore<Book> = EntityStore()
}
