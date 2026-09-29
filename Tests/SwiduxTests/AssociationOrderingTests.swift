import Foundation
import Testing

@testable import Swidux

private struct OrderedParent: Identifiable, Equatable, Sendable {
    var id: UUID
    var childIDs: [UUID]
}
private struct OrderedChild: Identifiable, Equatable, Sendable {
    var id: UUID
    var parentID: UUID?
    var title: String
}
private struct OrderedState: Sendable {
    var parents: EntityStore<OrderedParent>
    var children: EntityStore<OrderedChild>
}

@MainActor
@Suite("Association order")
struct AssociationOrderingTests {
    @Test("order metadata never creates ownership and missing IDs remain in the draft")
    func orderedNavigation() throws {
        let parentID = UUID()
        let unknown = UUID()
        let first = OrderedChild(id: UUID(), parentID: parentID, title: "First")
        let second = OrderedChild(id: UUID(), parentID: parentID, title: "Second")
        let foreign = OrderedChild(id: UUID(), parentID: UUID(), title: "Foreign")
        let parent = OrderedParent(id: parentID, childIDs: [unknown, second.id, foreign.id, second.id, first.id])
        var state = OrderedState(parents: EntityStore([parent]), children: EntityStore([first, second, foreign]))
        let association = try EntityAssociation(
            name: "children", parents: \OrderedState.parents, children: \OrderedState.children,
            owner: \OrderedChild.parentID, order: \OrderedParent.childIDs,
            requiredness: .optional, removal: .detach, parentDeletion: .detach)
        #expect(association.children(of: parentID, in: state).map(\.id) == [second.id, first.id])
        var catalog = EntityAssociationCatalog<OrderedState>()
        try catalog.register(association)
        let session = EntityEditSession(state: state, associations: catalog)
        try session.reorder([first.id, unknown, second.id], for: parentID, through: association)
        state.children.modify(second.id) { $0.title = "New" }
        #expect(session.apply(to: &state).wasApplied)
        #expect(association.children(of: parentID, in: state).map(\.id) == [first.id, second.id])
        #expect(state.parents[parentID]?.childIDs == [first.id, unknown, second.id])
        #expect(state.children[second.id]?.title == "New")
        #expect(state.children[foreign.id]?.parentID == foreign.parentID)
    }
}
