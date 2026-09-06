import Foundation
import Testing

@testable import Swidux

private struct MutableIdentityEntity: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
}

@Suite("EntityStore stable identity")
struct EntityStoreIdentityTests {
    @Test("inserting an entity under another ID rejects the invalid key")
    func insertingUnderDifferentIDFails() async {
        await #expect(processExitsWith: .failure) {
            var store = EntityStore<MutableIdentityEntity>()
            store[UUID()] = MutableIdentityEntity(id: UUID(), name: "mismatched")
        }
    }

    @Test("replacing an entity cannot take another stored entity's identity")
    func replacingWithDifferentIDFails() async {
        await #expect(processExitsWith: .failure) {
            let first = MutableIdentityEntity(id: UUID(), name: "first")
            let second = MutableIdentityEntity(id: UUID(), name: "second")
            var store = EntityStore([first, second])
            store[first.id] = second
        }
    }

    @Test("modify cannot change a stored entity's identity")
    func modifyingIdentityFails() async {
        await #expect(processExitsWith: .failure) {
            let entity = MutableIdentityEntity(id: UUID(), name: "original")
            var store = EntityStore([entity])
            store.modify(entity.id) { $0.id = UUID() }
        }
    }

    @Test("modify cannot collide with another stored entity's identity")
    func modifyingIdentityToExistingIDFails() async {
        await #expect(processExitsWith: .failure) {
            let first = MutableIdentityEntity(id: UUID(), name: "first")
            let second = MutableIdentityEntity(id: UUID(), name: "second")
            var store = EntityStore([first, second])
            store.modify(first.id) { $0.id = second.id }
        }
    }

    @Test("replacing an identity explicitly records the deletion and insertion")
    func replacingIdentityThroughDeleteAndInsert() {
        let original = MutableIdentityEntity(id: UUID(), name: "original")
        let replacement = MutableIdentityEntity(id: UUID(), name: "replacement")
        var store = EntityStore([original])

        store[original.id] = nil
        store[replacement.id] = replacement

        #expect(store.values == [replacement])
        #expect(store[original.id] == nil)
        #expect(!store.contains(original.id))
        #expect(store[replacement.id] == replacement)
        #expect(store.changes.deletions == [original.id])
        #expect(store.changes.upserts == [replacement.id])
    }
}
