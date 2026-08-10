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

/// Root state for the persistence tests.
///
/// `ui` is deliberately *not* a registered entity: it proves that a read path
/// leaves unregistered slices alone, including changes dispatched while the
/// read was in flight.
struct NotesState: Equatable, Sendable {
    var notes = EntityStore<Note>()
    var ui = NotesUI()
}

struct NotesUI: Equatable, Sendable {
    var searchText = ""
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

    // MARK: - Fetching by ID

    @MainActor
    @Test("fetch(ids:) returns only the rows asked for, whatever else the table holds")
    func fetchByIDsMaterializesOnlyTheRequested() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let db = EntityDB(modelContainer: container)
        let wanted = (0..<3).map { Note(id: UUID(), title: "wanted \($0)", pinned: false) }
        let noise = (0..<200).map { Note(id: UUID(), title: "noise \($0)", pinned: false) }
        try await db.apply(writes: wanted + noise, deletions: [], as: NoteModel.self)

        let rows = try await db.fetch(ids: wanted.map(\.id), of: Note.self)

        #expect(
            rows.sorted { $0.title < $1.title } == wanted,
            "a by-ID read must not materialize the rest of the table"
        )
    }

    @MainActor
    @Test("fetch(ids:) skips IDs with no row instead of failing")
    func fetchByIDsToleratesMisses() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let db = EntityDB(modelContainer: container)
        let present = Note(id: UUID(), title: "here", pinned: false)
        try await db.apply(writes: [present], deletions: [], as: NoteModel.self)

        let rows = try await db.fetch(ids: [present.id, UUID()], of: Note.self)

        #expect(rows == [present])
    }

    @MainActor
    @Test("fetch(ids:) of nothing touches the database not at all")
    func fetchByIDsOfEmptyIsEmpty() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let db = EntityDB(modelContainer: container)
        try await db.apply(
            writes: [Note(id: UUID(), title: "ignored", pinned: false)], deletions: [], as: NoteModel.self)

        #expect(try await db.fetch(ids: [], of: Note.self).isEmpty)
    }

    @MainActor
    @Test("fetch(ids:) spans the chunk boundary without dropping a row")
    func fetchByIDsLargerThanChunk() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let db = EntityDB(modelContainer: container)
        // One past the boundary in *both* directions: the request spans two
        // chunks, and the table holds rows the request must not pick up.
        let wanted = (0..<(EntityDB.batchFetchChunkSize + 1)).map {
            Note(id: UUID(), title: "wanted \($0)", pinned: false)
        }
        let noise = (0..<10).map { Note(id: UUID(), title: "noise \($0)", pinned: false) }
        try await db.apply(writes: wanted + noise, deletions: [], as: NoteModel.self)

        let rows = try await db.fetch(ids: wanted.map(\.id), of: Note.self)

        #expect(rows.count == wanted.count, "a request wider than one chunk must not lose its tail")
        #expect(Set(rows.map(\.id)) == Set(wanted.map(\.id)))
        #expect(rows.allSatisfy { $0.title.hasPrefix("wanted") }, "no noise row may ride along")
    }

    @Test(
        "IDs are chunked to stay under the bound-variable limit",
        arguments: [
            (0, 0), (1, 1), (499, 1), (500, 1), (501, 2), (1000, 2), (1001, 3),
        ]
    )
    func idsChunkToTheFetchLimit(count: Int, expectedChunks: Int) {
        // The batching claim is arithmetic, and asserting it here is honest
        // about that: there is no seam to count `ModelContext.fetch` calls, and
        // a timing test would be flaky. What the round trips *cost* rests on
        // `swiduxBatchFetchDescriptor` being an `IN (…)` predicate, which the
        // write path already stands on.
        let ids = (0..<count).map { _ in UUID() }

        let chunks = EntityDB.idChunks(ids)

        #expect(chunks.count == expectedChunks)
        #expect(chunks.allSatisfy { $0.count <= EntityDB.batchFetchChunkSize })
        #expect(chunks.flatMap { $0 }.count == count, "chunking must partition, not sample")
    }

    @MainActor
    @Test("rehydrate merges without clobbering live in-memory edits (rule #8)")
    func rehydratePreservesLiveEdits() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let coordinator = PersistenceCoordinator<NotesState, NotesAction>(
            entities: [.entity(\.notes)],
            container: container
        )
        let id = UUID()

        try await coordinator.database.upsert(Note(id: id, title: "disk", pinned: false), as: NoteModel.self)

        var initial = NotesState()
        await coordinator.hydrate(into: &initial)
        #expect(initial.notes[id]?.title == "disk")

        let plugins = PluginHost<NotesState, NotesAction>()
        plugins.register(coordinator.corePlugin)
        let store = Store(
            initialState: initial,
            reducer: notesReducer,
            plugins: plugins,
            persistencePlugin: coordinator.corePlugin
        )

        // An unflushed live edit.
        store.send(.add(Note(id: id, title: "live edit", pinned: true)))

        // Merge-based rehydrate must not overwrite the live edit.
        await coordinator.rehydrate(into: store)
        #expect(store.notes[id]?.title == "live edit")
    }
}

// MARK: - The by-identifier read

/// Drives `EntityDB.identities(of:asConcrete:)`, the package's only generic
/// context that builds a by-identifier fetch — and so the only one that can
/// reproduce the `-O` miscompile the generated descriptor exists to dodge. A
/// concrete call site never specializes a witness key path, so it would prove
/// nothing; these run under `swift test -c release` for the same reason.
@Suite("Resolving persistent identifiers to identities")
struct PersistentIDDescriptorTests {
    @MainActor
    @Test("identifiers resolve to identities, and only the ones asked for")
    func resolvesTheIdentifiersItIsGiven() async throws {
        let container = try makeNotesContainer()
        let wanted = Note(id: UUID(), title: "wanted", pinned: false)
        let identifiers = try seedNotes(container, [wanted, Note(id: UUID(), title: "noise", pinned: true)])
        let db = EntityDB(modelContainer: container)

        let resolved = try await db.identities(of: [identifiers[0]], asConcrete: NoteModel.self)

        #expect(resolved == [identifiers[0]: wanted.id], "no unasked-for row may ride along")
    }

    @MainActor
    @Test("an identifier whose row is gone is absent, not fatal")
    func aDeletedIdentifierIsAbsent() async throws {
        let container = try makeNotesContainer()
        let surviving = Note(id: UUID(), title: "kept", pinned: false)
        let doomed = Note(id: UUID(), title: "doomed", pinned: false)
        let identifiers = try seedNotes(container, [surviving, doomed])
        let db = EntityDB(modelContainer: container)
        try await db.apply(writes: [], deletions: [doomed.id], as: NoteModel.self)

        // Both are asked for. The read answers with what it finds; deciding
        // whether an absence is explicable belongs to the history scan, which
        // only gets the chance if this declines to trap on the way.
        let resolved = try await db.identities(of: identifiers, asConcrete: NoteModel.self)

        #expect(
            resolved == [identifiers[0]: surviving.id],
            "a deleted row must be absent, not resolved to something stale")
    }
}
