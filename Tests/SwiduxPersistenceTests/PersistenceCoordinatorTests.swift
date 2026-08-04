//
//  PersistenceCoordinatorTests.swift
//  SwiduxPersistenceTests
//
//  Covers the coordinator's two hydration paths: first-load hydrate (replace)
//  and post-launch rehydrate (merge, in-memory wins, additive-only).
//

import Foundation
import Swidux
import SwiftData
import Testing

// @testable for the `duringReadPhase` seam used by the lost-write tests.
@testable import SwiduxPersistence

@Suite("PersistenceCoordinator hydration")
@MainActor
struct PersistenceCoordinatorTests {
    private func makeCoordinator(
        debounce: Duration = .milliseconds(10)
    ) throws -> PersistenceCoordinator<NotesState, NotesAction> {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        return PersistenceCoordinator<NotesState, NotesAction>(
            entities: [.entity(\.notes)],
            container: container,
            debounce: debounce
        )
    }

    private func makeStore(
        _ coordinator: PersistenceCoordinator<NotesState, NotesAction>,
        initialState: NotesState = NotesState()
    ) -> Store<NotesState, NotesAction> {
        let plugins = PluginHost<NotesState, NotesAction>()
        plugins.register(coordinator.corePlugin)
        return Store(
            initialState: initialState,
            reducer: notesReducer,
            plugins: plugins,
            persistencePlugin: coordinator.corePlugin
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

        var initial = NotesState()
        let memoryShared = Note(id: sharedID, title: "memory edit", pinned: true)
        let memoryOnly = Note(id: UUID(), title: "memory only", pinned: false)
        initial.notes[memoryShared.id] = memoryShared
        initial.notes[memoryOnly.id] = memoryOnly
        let store = makeStore(coordinator, initialState: initial)

        await coordinator.rehydrate(into: store)

        #expect(store.notes[sharedID] == memoryShared, "the in-memory value is authoritative mid-session")
        #expect(store.notes[memoryOnly.id] == memoryOnly)
        #expect(store.notes[diskOnly.id] == diskOnly, "disk-only rows are merged in")
        #expect(store.notes.count == 3)
    }

    @Test("rehydrate is additive-only: a disk deletion does not remove a live entity")
    func rehydrateNeverRemoves() async throws {
        let coordinator = try makeCoordinator()

        var initial = NotesState()
        let live = Note(id: UUID(), title: "live", pinned: false)
        initial.notes[live.id] = live
        initial.notes.resetChanges()
        let store = makeStore(coordinator, initialState: initial)

        // Disk holds nothing (as if another device deleted the row).
        await coordinator.rehydrate(into: store)

        #expect(store.notes[live.id] == live)
    }

    @Test("rehydrate flushes first, so an unflushed local delete is not resurrected")
    func rehydrateDoesNotResurrectUnflushedDelete() async throws {
        // Large debounce so the scheduled flush never fires on its own during the
        // test — the pending delete stays buffered until rehydrate flushes it.
        let coordinator = try makeCoordinator(debounce: .seconds(30))
        let keep = UUID()
        let doomed = UUID()
        let store = makeStore(coordinator)

        // Persist two notes through the plugin pipeline.
        store.send(.add(Note(id: keep, title: "keep", pinned: false)))
        store.send(.add(Note(id: doomed, title: "doomed", pinned: false)))
        await coordinator.corePlugin.flush()

        // Delete one in memory — now buffered but NOT flushed to disk.
        store.send(.remove(doomed))
        #expect(store.notes[doomed] == nil)

        // A remote-change refresh arrives mid-window. rehydrate must flush the
        // pending delete first, so the merge can't read the stale disk row.
        await coordinator.rehydrate(into: store)

        #expect(store.notes[doomed] == nil)  // no zombie in memory
        #expect(store.notes.count == 1)
        let onDisk = try await coordinator.database.fetchAll(NoteModel.self)
        #expect(onDisk.count == 1)  // and gone from disk
        #expect(onDisk.first?.id == keep)
    }

    // MARK: - Lost writes

    @Test("rehydrate keeps a write dispatched while the reads are in flight")
    func rehydrateKeepsWriteLandingDuringReads() async throws {
        let coordinator = try makeCoordinator(debounce: .seconds(30))
        let diskRow = Note(id: UUID(), title: "disk", pinned: false)
        try await coordinator.database.apply(writes: [diskRow], deletions: [], as: NoteModel.self)
        let store = makeStore(coordinator)

        // A dispatch lands after the flush and after the fetch, in the exact
        // window a caller holding `inout State` across those awaits would lose.
        let live = Note(id: UUID(), title: "typed while syncing", pinned: false)
        coordinator.duringReadPhase = { store.send(.add(live)) }

        await coordinator.rehydrate(into: store)

        #expect(store.notes[live.id] == live, "a write dispatched during the reads must survive the merge")
        #expect(store.notes[diskRow.id] == diskRow, "and the disk row must still arrive")
        #expect(store.notes.count == 2)
    }

    @Test("the hand-rolled pack/await/unpack idiom loses that write — why rehydrate takes the store")
    func handRolledIdiomLosesTheWrite() async throws {
        let coordinator = try makeCoordinator(debounce: .seconds(30))
        let store = makeStore(coordinator)

        // The shape this API replaces: snapshot packed BEFORE the awaits.
        var snapshot = NotesState(observer: store.observer)

        let live = Note(id: UUID(), title: "typed while syncing", pinned: false)
        coordinator.duringReadPhase = { store.send(.add(live)) }
        await coordinator.hydrate(into: &snapshot)
        NotesState.apply(snapshot, to: store.observer)

        // Pins the hazard deliberately: if a future refactor closes this
        // elsewhere, this test fails and says so, rather than rotting.
        #expect(
            store.notes[live.id] == nil,
            "the stale snapshot overwrites the concurrent dispatch — this is the bug mutate(awaiting:merging:) exists to prevent"
        )
    }

    @Test("hydrate into a store replaces entities but preserves unregistered slices")
    func hydrateIntoStorePreservesOtherSlices() async throws {
        let coordinator = try makeCoordinator(debounce: .seconds(30))
        let disk = Note(id: UUID(), title: "disk", pinned: false)
        try await coordinator.database.apply(writes: [disk], deletions: [], as: NoteModel.self)

        var initial = NotesState()
        initial.notes[UUID()] = Note(id: UUID(), title: "stale", pinned: false)
        initial.notes.resetChanges()
        let store = makeStore(coordinator, initialState: initial)

        // `ui` is not a registered entity, and this dispatch lands mid-read.
        coordinator.duringReadPhase = { store.send(.setSearchText("typed")) }

        await coordinator.hydrate(into: store)

        #expect(store.notes.values == [disk], "registered entities are replaced on first load")
        #expect(store.ui.searchText == "typed", "unregistered slices survive, including concurrent edits")
    }
}
