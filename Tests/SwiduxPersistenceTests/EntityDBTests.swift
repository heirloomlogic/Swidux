//
//  EntityDBTests.swift
//  SwiduxPersistenceTests
//
//  Exercises the generated @Persisted shadow + generic EntityDB against an
//  in-memory SwiftData store, plus the rule-#8 merge-on-rehydrate guarantee.
//

import Foundation
import Swidux
import SwiduxPersistence
import SwiftData
import Testing

// MARK: - Test fixtures

@Persisted
struct Note: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var pinned: Bool
}

struct NotesState {
    var notes = EntityStore<Note>()
}

// MARK: - Tests

@Suite("EntityDB")
struct EntityDBTests {
    @MainActor
    @Test("upsert inserts, upsert updates, delete removes")
    func upsertFetchDelete() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let db = EntityDB(modelContainer: container)
        let id = UUID()

        try await db.upsert(Note(id: id, title: "A", pinned: false), as: NoteModel.self)
        var all = try await db.fetchAll(NoteModel.self)
        #expect(all.count == 1)
        #expect(all.first?.title == "A")

        try await db.upsert(Note(id: id, title: "B", pinned: true), as: NoteModel.self)
        all = try await db.fetchAll(NoteModel.self)
        #expect(all.count == 1)
        #expect(all.first?.title == "B")
        #expect(all.first?.pinned == true)

        try await db.delete(id: id, as: NoteModel.self)
        all = try await db.fetchAll(NoteModel.self)
        #expect(all.isEmpty)
    }

    @MainActor
    @Test("apply persists a whole batch — inserts, updates, and deletions — in one call")
    func applyBatch() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let db = EntityDB(modelContainer: container)
        let keepID = UUID()
        let updateID = UUID()
        let removeID = UUID()

        try await db.upsert(Note(id: updateID, title: "old", pinned: false), as: NoteModel.self)
        try await db.upsert(Note(id: removeID, title: "doomed", pinned: false), as: NoteModel.self)

        try await db.apply(
            writes: [
                Note(id: keepID, title: "new", pinned: false),
                Note(id: updateID, title: "updated", pinned: true),
            ],
            deletions: [removeID],
            as: NoteModel.self
        )

        let all = try await db.fetchAll(NoteModel.self)
        #expect(all.count == 2)
        #expect(all.first { $0.id == keepID }?.title == "new")
        #expect(all.first { $0.id == updateID }?.title == "updated")
        #expect(all.first { $0.id == removeID } == nil)
    }

    @MainActor
    @Test("rehydrate merges without clobbering live in-memory edits (rule #8)")
    func rehydratePreservesLiveEdits() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let coordinator = PersistenceCoordinator<NotesState, Never>(
            entities: [.entity(\.notes)],
            container: container
        )
        let id = UUID()

        try await coordinator.database.upsert(Note(id: id, title: "disk", pinned: false), as: NoteModel.self)

        var state = NotesState()
        await coordinator.hydrate(into: &state)
        #expect(state.notes[id]?.title == "disk")

        // An unflushed live edit.
        state.notes[id] = Note(id: id, title: "live edit", pinned: true)

        // Merge-based rehydrate must not overwrite the live edit.
        await coordinator.rehydrate(into: &state)
        #expect(state.notes[id]?.title == "live edit")
    }
}
