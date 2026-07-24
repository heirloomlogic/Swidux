//
//  EntityDBTests.swift
//  SwiduxPersistenceTests
//
//  Exercises the generated @Persisted shadow + generic EntityDB against an
//  in-memory SwiftData store, plus the rule-#8 merge-on-rehydrate guarantee.
//

import Foundation
import Swidux
import SwiftData
import Testing

// @testable for `EntityDB.batchFetchChunkSize` in the chunking test.
@testable import SwiduxPersistence

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
    @Test("apply handles a mixed insert/update/delete batch of many rows")
    func applyMixedBatch() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let db = EntityDB(modelContainer: container)
        let updateIDs = (0..<5).map { _ in UUID() }
        let removeIDs = (0..<5).map { _ in UUID() }
        let insertIDs = (0..<10).map { _ in UUID() }

        // Seed the rows that will be updated or deleted.
        try await db.apply(
            writes: updateIDs.map { Note(id: $0, title: "old", pinned: false) }
                + removeIDs.map { Note(id: $0, title: "doomed", pinned: false) },
            deletions: [],
            as: NoteModel.self
        )

        try await db.apply(
            writes: insertIDs.map { Note(id: $0, title: "inserted", pinned: false) }
                + updateIDs.map { Note(id: $0, title: "updated", pinned: true) },
            deletions: Set(removeIDs),
            as: NoteModel.self
        )

        let all = try await db.fetchAll(NoteModel.self)
        #expect(all.count == 15)
        for id in insertIDs {
            #expect(all.first { $0.id == id }?.title == "inserted")
        }
        for id in updateIDs {
            #expect(all.first { $0.id == id }?.title == "updated")
            #expect(all.first { $0.id == id }?.pinned == true)
        }
        for id in removeIDs {
            #expect(all.first { $0.id == id } == nil)
        }
    }

    @MainActor
    @Test("apply deletion of an ID absent from the database is a no-op")
    func applyDeletionOfAbsentID() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let db = EntityDB(modelContainer: container)
        let keepID = UUID()

        try await db.upsert(Note(id: keepID, title: "keep", pinned: false), as: NoteModel.self)

        try await db.apply(
            writes: [],
            deletions: [UUID(), UUID()],
            as: NoteModel.self
        )

        let all = try await db.fetchAll(NoteModel.self)
        #expect(all.count == 1)
        #expect(all.first?.id == keepID)
    }

    @MainActor
    @Test("apply handles a batch larger than the fetch chunk size")
    func applyBatchLargerThanChunk() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let db = EntityDB(modelContainer: container)
        let count = EntityDB.batchFetchChunkSize + 1
        let ids = (0..<count).map { _ in UUID() }

        // Insert across the chunk boundary, then update every row so the
        // batched fetch itself must span two chunks.
        try await db.apply(
            writes: ids.map { Note(id: $0, title: "v1", pinned: false) },
            deletions: [],
            as: NoteModel.self
        )
        try await db.apply(
            writes: ids.map { Note(id: $0, title: "v2", pinned: true) },
            deletions: [],
            as: NoteModel.self
        )

        let all = try await db.fetchAll(NoteModel.self)
        #expect(all.count == count)
        #expect(all.allSatisfy { $0.title == "v2" })
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
