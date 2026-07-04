//
//  PersistenceCoordinatorTests.swift
//  SwiduxPersistenceTests
//
//  Covers the coordinator's two hydration paths: first-load hydrate (replace)
//  and post-launch rehydrate (merge, in-memory wins, additive-only).
//

import Foundation
import Swidux
import SwiduxPersistence
import SwiftData
import Testing

@Suite("PersistenceCoordinator hydration")
@MainActor
struct PersistenceCoordinatorTests {
    private func makeCoordinator(
        debounce: Duration = .milliseconds(10)
    ) throws -> PersistenceCoordinator<NotesState, Never> {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        return PersistenceCoordinator<NotesState, Never>(
            entities: [.entity(\.notes)],
            container: container,
            debounce: debounce
        )
    }

    @Test("hydrate replaces the EntityStore with the on-disk rows")
    func hydrateReplaces() async throws {
        let coordinator = try makeCoordinator()
        let disk = Note(id: UUID(), title: "disk", pinned: false)
        try await coordinator.database.apply(writes: [disk], deletions: [], as: NoteModel.self)

        // First-load semantics: whatever the state held before is replaced.
        var state = NotesState()
        let stale = Note(id: UUID(), title: "stale", pinned: true)
        state.notes[stale.id] = stale
        state.notes.resetChanges()

        await coordinator.hydrate(into: &state)

        #expect(state.notes.values == [disk])
    }

    @Test("rehydrate merges: in-memory wins per ID, disk-only rows appear")
    func rehydrateMergesPreferringMemory() async throws {
        let coordinator = try makeCoordinator()
        let sharedID = UUID()
        let diskShared = Note(id: sharedID, title: "disk edit", pinned: false)
        let diskOnly = Note(id: UUID(), title: "disk only", pinned: false)
        try await coordinator.database.apply(
            writes: [diskShared, diskOnly], deletions: [], as: NoteModel.self
        )

        var state = NotesState()
        let memoryShared = Note(id: sharedID, title: "memory edit", pinned: true)
        let memoryOnly = Note(id: UUID(), title: "memory only", pinned: false)
        state.notes[memoryShared.id] = memoryShared
        state.notes[memoryOnly.id] = memoryOnly

        await coordinator.rehydrate(into: &state)

        #expect(state.notes[sharedID] == memoryShared, "the in-memory value is authoritative mid-session")
        #expect(state.notes[memoryOnly.id] == memoryOnly)
        #expect(state.notes[diskOnly.id] == diskOnly, "disk-only rows are merged in")
        #expect(state.notes.count == 3)
    }

    @Test("rehydrate is additive-only: a disk deletion does not remove a live entity")
    func rehydrateNeverRemoves() async throws {
        let coordinator = try makeCoordinator()

        var state = NotesState()
        let live = Note(id: UUID(), title: "live", pinned: false)
        state.notes[live.id] = live
        state.notes.resetChanges()

        // Disk holds nothing (as if another device deleted the row).
        await coordinator.rehydrate(into: &state)

        #expect(state.notes[live.id] == live)
    }

    @Test("rehydrate flushes first, so an unflushed local delete is not resurrected")
    func rehydrateDoesNotResurrectUnflushedDelete() async throws {
        // Large debounce so the scheduled flush never fires on its own during the
        // test — the pending delete stays buffered until rehydrate flushes it.
        let coordinator = try makeCoordinator(debounce: .seconds(30))
        let keep = UUID()
        let doomed = UUID()
        var state = NotesState()

        // Persist two notes through the plugin pipeline.
        state.notes[keep] = Note(id: keep, title: "keep", pinned: false)
        state.notes[doomed] = Note(id: doomed, title: "doomed", pinned: false)
        coordinator.corePlugin.drainAndScheduleFlush(&state)
        await coordinator.corePlugin.flush()

        // Delete one in memory and drain — now buffered but NOT flushed to disk.
        state.notes[doomed] = nil
        coordinator.corePlugin.drainAndScheduleFlush(&state)
        #expect(state.notes[doomed] == nil)

        // A remote-change refresh arrives mid-window. rehydrate must flush the
        // pending delete first, so the merge can't read the stale disk row.
        await coordinator.rehydrate(into: &state)

        #expect(state.notes[doomed] == nil)  // no zombie in memory
        #expect(state.notes.count == 1)
        let onDisk = try await coordinator.database.fetchAll(NoteModel.self)
        #expect(onDisk.count == 1)  // and gone from disk
        #expect(onDisk.first?.id == keep)
    }
}
