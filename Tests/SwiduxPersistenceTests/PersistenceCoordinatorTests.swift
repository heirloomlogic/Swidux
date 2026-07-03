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
    private func makeCoordinator() throws -> PersistenceCoordinator<NotesState, Never> {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        return PersistenceCoordinator<NotesState, Never>(
            entities: [.entity(\.notes)],
            container: container,
            debounce: .milliseconds(10)
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
}
