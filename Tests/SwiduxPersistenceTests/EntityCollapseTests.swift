//
//  EntityCollapseTests.swift
//  SwiduxPersistenceTests
//
//  The opt-in collapse hook: removing duplicate rows requires app knowledge, so
//  nothing is deleted unless a resolver says so.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Helpers

/// Deterministic across devices: prefers the pinned row, then the lexically
/// smaller title. Never consults `persistentModelID` or ordering.
private let preferPinned: @Sendable ([Note]) -> [Note] = EntityCollapse.byID { a, b in
    if a.pinned != b.pinned { return a.pinned ? a : b }
    return a.title <= b.title ? a : b
}

// MARK: - EntityDB

@Suite("EntityDB.collapseDuplicates")
struct EntityDBCollapseTests {
    @MainActor
    @Test("rows sharing a surviving ID converge on the resolver's winner, and are not deleted")
    func rowsSharingASurvivingIDConverge() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let id = UUID()
        try seedNotes(
            container,
            [
                Note(id: id, title: "b", pinned: false),
                Note(id: id, title: "a", pinned: true),
                Note(id: UUID(), title: "other", pinned: false),
            ])

        let outcome = try await db.collapseDuplicates(as: NoteModel.self, using: preferPinned)

        #expect(outcome.survivors.count == 2, "one value per ID")
        #expect(outcome.removedIDs.isEmpty, "no ID disappeared")
        let rows = try rawNoteRows(container)
        #expect(
            rows.count == 3,
            """
            Both rows for the shared ID are kept. Nothing replicated distinguishes them, so two devices \
            could delete different ones and lose both — see EntityCollapse.
            """
        )
        #expect(
            rows.filter { $0.id == id }.allSatisfy { $0.title == "a" && $0.pinned },
            "instead they converge on the resolver's winner, so any of them is the right answer"
        )
        #expect(
            outcome.duplicateRowCount == 1,
            """
            A collapse that removes no ID still leaves duplicates on disk, so reporting zero here \
            would tell an app its data is clean when it isn't.
            """
        )
    }

    @MainActor
    @Test("collapse writes back a survivor whose value it changed")
    func collapseWritesBackMutatedSurvivor() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let id = UUID()
        try seedNotes(container, [Note(id: id, title: "original", pinned: false)])

        try await db.collapseDuplicates(as: NoteModel.self) { rows in
            rows.map { Note(id: $0.id, title: $0.title.uppercased(), pinned: $0.pinned) }
        }

        #expect(try rawNoteRows(container).first?.title == "ORIGINAL")
    }

    @MainActor
    @Test("an identity collapse changes nothing")
    func identityCollapseIsANoOp() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let notes = [Note(id: UUID(), title: "a", pinned: false), Note(id: UUID(), title: "b", pinned: true)]
        try seedNotes(container, notes)

        let outcome = try await db.collapseDuplicates(as: NoteModel.self) { $0 }

        #expect(outcome.removedIDs.isEmpty)
        #expect(Set(try rawNoteRows(container).map(\.id)) == Set(notes.map(\.id)))
    }

    @MainActor
    @Test("dropping an entire ID reports it as removed and deletes every row for it")
    func droppingAnIDRemovesAllItsRows() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let doomed = UUID()
        let kept = UUID()
        try seedNotes(
            container,
            [
                Note(id: doomed, title: "x", pinned: false),
                Note(id: doomed, title: "x", pinned: false),
                Note(id: kept, title: "keep", pinned: false),
            ])

        let outcome = try await db.collapseDuplicates(as: NoteModel.self) { rows in
            rows.filter { $0.id != doomed }
        }

        #expect(outcome.removedIDs == [doomed])
        #expect(try rawNoteRows(container).map(\.id) == [kept])
    }

    @MainActor
    @Test("the singleton case: two rows with different IDs merge into one")
    func singletonMerge() async throws {
        // Two fresh installs each minted their own settings row, so the IDs
        // differ and no ID-keyed resolver could ever pair them.
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let a = Note(id: UUID(), title: "device A", pinned: false)
        let b = Note(id: UUID(), title: "device B", pinned: true)
        try seedNotes(container, [a, b])

        let outcome = try await db.collapseDuplicates(as: NoteModel.self) { rows in
            guard rows.count > 1 else { return rows }
            // `id` is replicated, so min-by-UUID is the same choice everywhere.
            let winner = rows.min { $0.id.uuidString < $1.id.uuidString }!
            return [Note(id: winner.id, title: winner.title, pinned: rows.contains { $0.pinned })]
        }

        #expect(outcome.survivors.count == 1)
        #expect(outcome.removedIDs.count == 1)
        let rows = try rawNoteRows(container)
        #expect(rows.count == 1)
        #expect(rows.first?.pinned == true, "the merged value carries both devices' state")
    }
}

// MARK: - Coordinator wiring

@Suite("PersistenceCoordinator collapse")
@MainActor
struct CoordinatorCollapseTests {
    private func makeCoordinator(
        collapse: (@Sendable ([Note]) -> [Note])? = nil
    ) throws -> PersistenceCoordinator<NotesState, NotesAction> {
        try makeNotesCoordinator(debounce: .seconds(30), collapse: collapse)
    }

    @Test("with no resolver registered, duplicates survive on disk")
    func withoutAResolverNothingIsDeleted() async throws {
        let coordinator = try makeCoordinator()
        let id = UUID()
        let context = ModelContext(coordinator.handle.db.modelContainer)
        context.insert(try NoteModel(from: Note(id: id, title: "a", pinned: false)))
        context.insert(try NoteModel(from: Note(id: id, title: "b", pinned: false)))
        try context.save()

        var state = NotesState()
        await coordinator.hydrate(into: &state)

        #expect(state.notes.count == 1, "reads always collapse")
        let rows = try ModelContext(coordinator.handle.db.modelContainer)
            .fetch(FetchDescriptor<NoteModel>())
        #expect(rows.count == 2, "but nothing is deleted without an app-supplied resolver")
    }

    @Test("hydrate runs the resolver, converging duplicate rows on the winner")
    func hydrateCollapses() async throws {
        let coordinator = try makeCoordinator(collapse: preferPinned)
        let id = UUID()
        let context = ModelContext(coordinator.handle.db.modelContainer)
        context.insert(try NoteModel(from: Note(id: id, title: "b", pinned: false)))
        context.insert(try NoteModel(from: Note(id: id, title: "a", pinned: true)))
        try context.save()

        var state = NotesState()
        await coordinator.hydrate(into: &state)

        #expect(state.notes[id]?.title == "a")
        let rows = try ModelContext(coordinator.handle.db.modelContainer)
            .fetch(FetchDescriptor<NoteModel>())
        #expect(rows.allSatisfy { $0.title == "a" })
    }

    @Test("rehydrate's collapse removes a dropped ID from live state, and the merge cannot resurrect it")
    func rehydrateCollapseRemovesFromLiveState() async throws {
        let doomed = UUID()
        let kept = UUID()
        // A singleton-style resolver: it drops an entire ID, which is the case
        // deletion is safe for.
        let coordinator = try makeCoordinator(collapse: { rows in rows.filter { $0.id != doomed } })
        try await coordinator.database.apply(
            writes: [Note(id: doomed, title: "doomed", pinned: false), Note(id: kept, title: "keep", pinned: false)],
            deletions: [],
            as: NoteModel.self)

        // Live state holds both, as it would after a hydrate that predates the
        // duplicate arriving from another device.
        var initial = NotesState()
        initial.notes[doomed] = Note(id: doomed, title: "doomed", pinned: false)
        initial.notes[kept] = Note(id: kept, title: "keep", pinned: false)
        initial.notes.resetChanges()
        let store = makeNotesStore(coordinator, initialState: initial)

        await coordinator.rehydrate(into: store)

        #expect(store.notes[doomed] == nil, "a collapsed-away ID must not linger in memory as a zombie")
        #expect(store.notes[kept] != nil)
        let rows = try ModelContext(coordinator.handle.db.modelContainer)
            .fetch(FetchDescriptor<NoteModel>())
        #expect(rows.map(\.id) == [kept], "and it is gone from disk")
    }

    @Test("collapseDuplicates can be run on demand, leaving unrelated state alone")
    func onDemandCollapse() async throws {
        let doomed = UUID()
        let coordinator = try makeCoordinator(collapse: { rows in rows.filter { $0.id != doomed } })
        let kept = Note(id: UUID(), title: "keep", pinned: false)
        try await coordinator.database.apply(
            writes: [Note(id: doomed, title: "doomed", pinned: false), kept], deletions: [], as: NoteModel.self)

        var state = NotesState()
        state.notes[doomed] = Note(id: doomed, title: "doomed", pinned: false)
        state.notes[kept.id] = kept
        state.notes.resetChanges()
        // An unrelated live edit must survive the repair pass.
        state.ui.searchText = "typed"

        await coordinator.collapseDuplicates(into: &state)

        #expect(state.notes[doomed] == nil)
        #expect(state.notes[kept.id] != nil)
        #expect(state.ui.searchText == "typed")
    }
}
