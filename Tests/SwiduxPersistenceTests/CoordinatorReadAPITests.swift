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
