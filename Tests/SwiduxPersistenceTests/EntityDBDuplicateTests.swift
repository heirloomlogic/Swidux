//
//  EntityDBDuplicateTests.swift
//  SwiduxPersistenceTests
//
//  `@Persisted` emits no `@Attribute(.unique)` on `id` (CloudKit forbids unique
//  constraints), so duplicate-ID rows are a legitimate on-disk state. These
//  tests pin the convergent semantics that follow: writes touch every matching
//  row, deletions remove every matching row, and reads collapse.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Tests

@Suite("EntityDB duplicate rows")
struct EntityDBDuplicateTests {
    @MainActor
    @Test("upsert updates every row sharing an ID, leaving no stale copy")
    func upsertUpdatesAllDuplicates() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let id = UUID()
        try seedDuplicates(container, id: id, title: "old", count: 3)

        try await db.upsert(Note(id: id, title: "new", pinned: true), as: NoteModel.self)

        let rows = try rawNoteRows(container)
        #expect(rows.count == 3, "upsert must not delete duplicates — that loses data under CloudKit")
        #expect(
            rows.allSatisfy { $0.title == "new" && $0.pinned },
            "every duplicate must converge to the written value, not just an arbitrary first match"
        )
    }

    @MainActor
    @Test("upsert with no matching row still inserts exactly one")
    func upsertInsertsOnce() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)

        try await db.upsert(Note(id: UUID(), title: "A", pinned: false), as: NoteModel.self)

        #expect(try rawNoteRows(container).count == 1)
    }

    @MainActor
    @Test("delete removes every row sharing an ID, so nothing resurrects")
    func deleteRemovesAllDuplicates() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let id = UUID()
        try seedDuplicates(container, id: id, title: "doomed", count: 4)

        try await db.delete(id: id, as: NoteModel.self)

        #expect(try rawNoteRows(container).isEmpty, "a surviving duplicate resurrects the entity on next hydration")
        #expect(try await db.fetchAll(NoteModel.self).isEmpty)
    }

    @MainActor
    @Test("apply deletion removes every duplicate row")
    func applyDeletionRemovesAllDuplicates() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let id = UUID()
        try seedDuplicates(container, id: id, title: "doomed", count: 3)

        try await db.apply(writes: [], deletions: [id], as: NoteModel.self)

        #expect(try rawNoteRows(container).isEmpty)
    }

    @MainActor
    @Test("apply write updates every duplicate row")
    func applyWriteUpdatesAllDuplicates() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let id = UUID()
        try seedDuplicates(container, id: id, title: "old", count: 3)

        try await db.apply(
            writes: [Note(id: id, title: "new", pinned: false)], deletions: [], as: NoteModel.self)

        let rows = try rawNoteRows(container)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.title == "new" })
    }

    @MainActor
    @Test("apply writing then deleting the same ID leaves nothing behind")
    func applyWriteThenDeleteAcrossDuplicates() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let id = UUID()
        try seedDuplicates(container, id: id, title: "old", count: 2)

        // Both halves of the batch touch the same ID: the write updates both
        // rows, the deletion must then remove both, not just one.
        try await db.apply(
            writes: [Note(id: id, title: "new", pinned: false)],
            deletions: [id],
            as: NoteModel.self)

        #expect(try rawNoteRows(container).isEmpty)
    }

    @MainActor
    @Test("duplicates spanning the batch-fetch chunk boundary are all grouped")
    func duplicatesAcrossChunkBoundary() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)

        // More IDs than one chunk holds, so the grouping loop runs several
        // times; each ID is duplicated so the accumulator must append across
        // iterations rather than overwrite.
        let ids = (0..<(EntityDB.batchFetchChunkSize + 20)).map { _ in UUID() }
        let context = ModelContext(container)
        for id in ids {
            context.insert(NoteModel(from: Note(id: id, title: "old", pinned: false)))
            context.insert(NoteModel(from: Note(id: id, title: "old", pinned: false)))
        }
        try context.save()

        try await db.apply(
            writes: ids.map { Note(id: $0, title: "new", pinned: false) },
            deletions: [],
            as: NoteModel.self)

        let rows = try rawNoteRows(container)
        #expect(rows.count == ids.count * 2)
        #expect(
            rows.allSatisfy { $0.title == "new" },
            "a row missed by the chunked grouping would keep its old value"
        )
    }

    @MainActor
    @Test("fetchAll collapses duplicates to the first row in fetch order")
    func fetchAllCollapses() async throws {
        let container = try makeNotesContainer()
        let db = EntityDB(modelContainer: container)
        let duplicated = UUID()
        let unique = UUID()
        try seedDuplicates(container, id: duplicated, title: "dup", count: 3)
        try await db.upsert(Note(id: unique, title: "solo", pinned: false), as: NoteModel.self)

        let all = try await db.fetchAll(NoteModel.self)

        #expect(all.count == 2, "EntityStore cannot represent duplicates; fetchAll must collapse them")
        #expect(all.filter { $0.id == duplicated }.count == 1)
        #expect(try rawNoteRows(container).count == 4, "collapsing on read must not delete anything on disk")
    }
}
