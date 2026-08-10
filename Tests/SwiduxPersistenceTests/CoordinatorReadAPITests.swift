//
//  CoordinatorReadAPITests.swift
//  SwiduxPersistenceTests
//
//  The fetch-without-mutate read API: reading rows should not require a merge,
//  and must not present an unreadable database as "no data".
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

@Suite("PersistenceCoordinator reads")
@MainActor
struct CoordinatorReadAPITests {
    @Test("fetchAll(of:) returns domain values and leaves state alone")
    func fetchAllReturnsDomainValues() async throws {
        let coordinator = try makeNotesCoordinator()
        let note = Note(id: UUID(), title: "disk", pinned: true)
        try await coordinator.database.apply(writes: [note], deletions: [], as: NoteModel.self)

        let rows = try await coordinator.fetchAll(of: Note.self)

        #expect(rows == [note])
    }

    @Test("fetchAll(of:) flushes pending writes first, so it can't read a stale row")
    func fetchAllFlushesByDefault() async throws {
        // Debounce long enough that nothing flushes on its own.
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        var state = NotesState()
        let note = Note(id: UUID(), title: "just typed", pinned: false)
        state.notes[note.id] = note
        coordinator.corePlugin.drainAndScheduleFlush(&state)

        let rows = try await coordinator.fetchAll(of: Note.self)

        #expect(rows == [note], "a buffered write must be on disk before the read returns")
    }

    @Test("fetchAll(of:flushPending: false) sees the pre-flush disk state")
    func fetchAllCanSkipTheFlush() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        var state = NotesState()
        state.notes[UUID()] = Note(id: UUID(), title: "just typed", pinned: false)
        coordinator.corePlugin.drainAndScheduleFlush(&state)

        let rows = try await coordinator.fetchAll(of: Note.self, flushPending: false)

        #expect(rows.isEmpty, "skipping the flush means the buffered write is not visible yet")
    }

    // Note: the "reports to onFailure and rethrows" branch of `fetchAll(of:)`
    // has no test. There is no reliable way to make `ModelContext.fetch` throw
    // from a test: fetching a type absent from the container's schema returns
    // an empty result rather than an error, and corrupting the store file is
    // served from cache. Left uncovered deliberately rather than faked.

    @Test("fetch(ids:of:) returns only the named rows and leaves state alone")
    func fetchByIDsReturnsNamedRows() async throws {
        let coordinator = try makeNotesCoordinator()
        let wanted = Note(id: UUID(), title: "wanted", pinned: true)
        let other = Note(id: UUID(), title: "other", pinned: false)
        try await coordinator.database.apply(writes: [wanted, other], deletions: [], as: NoteModel.self)

        let rows = try await coordinator.fetch(ids: [wanted.id], of: Note.self)

        #expect(rows == [wanted])
    }

    @Test("fetch(ids:of:) flushes pending writes first, so it can't read a stale row")
    func fetchByIDsFlushesByDefault() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        var state = NotesState()
        let note = Note(id: UUID(), title: "just typed", pinned: false)
        state.notes[note.id] = note
        coordinator.corePlugin.drainAndScheduleFlush(&state)

        let rows = try await coordinator.fetch(ids: [note.id], of: Note.self)

        #expect(rows == [note], "a buffered write must be on disk before the read returns")
    }

    @Test("fetch(ids:of:) reports the duplicates it collapsed")
    func fetchByIDsReportsDuplicates() async throws {
        let diagnostics = SendableBox<[PersistenceDiagnostic]>([])
        let container = try makeNotesContainer()
        let coordinator = try makeNotesCoordinator(
            container: container,
            onDiagnostic: { diagnostic in diagnostics.withValue { $0.append(diagnostic) } })
        let id = UUID()
        try seedDuplicates(container, id: id, title: "dup", count: 3)

        let rows = try await coordinator.fetch(ids: [id], of: Note.self)

        #expect(rows.count == 1)
        #expect(diagnostics.value.contains(.duplicateRowsCollapsed(entityType: "Note", count: 2)))
    }

    @Test("snapshot(of:) yields a change-free EntityStore")
    func snapshotRecordsNoChanges() async throws {
        let coordinator = try makeNotesCoordinator()
        let note = Note(id: UUID(), title: "disk", pinned: false)
        try await coordinator.database.apply(writes: [note], deletions: [], as: NoteModel.self)

        let snapshot = try await coordinator.snapshot(of: Note.self)

        #expect(snapshot.values == [note])
        #expect(snapshot.changes.isEmpty, "a snapshot is hydration, not an edit — it must not schedule writes")
    }
}
