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
    @Test("hydrate replaces the EntityStore with the on-disk rows")
    func hydrateReplaces() async throws {
        let coordinator = try makeNotesCoordinator()
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

    @Test("an unflushed local edit wins over the stored row, and disk-only rows still appear")
    func rehydrateKeepsUnflushedLocalEdits() async throws {
        let coordinator = try makeNotesCoordinator()
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
        // Deliberately NOT resetChanges(): these are un-drained local edits, so
        // storage has no authority over them even under `.preferRemote`.
        let store = makeNotesStore(coordinator, initialState: initial)

        await coordinator.rehydrate(into: store)

        #expect(store.notes[sharedID] == memoryShared, "an unflushed local edit is never overwritten")
        #expect(store.notes[memoryOnly.id] == memoryOnly, "nor removed for being absent from storage")
        #expect(store.notes[diskOnly.id] == diskOnly, "storage-only rows are merged in")
        #expect(store.notes.count == 3)
    }

    @Test("an empty snapshot never removes anything — it can't be told from an unreadable store")
    func rehydrateKeepsEverythingWhenSnapshotIsEmpty() async throws {
        let coordinator = try makeNotesCoordinator()

        var initial = NotesState()
        let live = Note(id: UUID(), title: "live", pinned: false)
        initial.notes[live.id] = live
        initial.notes.resetChanges()  // clean: storage would otherwise be authoritative
        let store = makeNotesStore(coordinator, initialState: initial)

        // Disk holds nothing. That looks identical to a container that is
        // rebuilt, mid-import, or unreadable, so absence proves nothing.
        await coordinator.rehydrate(into: store)

        #expect(store.notes[live.id] == live)
    }

    // MARK: - Remote changes surfacing

    @Test("a remote edit to a clean entity surfaces mid-session")
    func rehydrateSurfacesRemoteEdit() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "original", pinned: false)))
        await coordinator.corePlugin.flush()  // clean: memory matches storage

        // Another device edits the row.
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: true)], deletions: [], as: NoteModel.self)

        await coordinator.rehydrate(into: store)

        #expect(store.notes[id]?.title == "edited elsewhere")
        #expect(store.notes[id]?.pinned == true)
    }

    @Test("a remote deletion surfaces mid-session, and is not echoed back as a local one")
    func rehydrateSurfacesRemoteDeletion() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let doomed = UUID()
        let kept = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: doomed, title: "doomed", pinned: false)))
        store.send(.add(Note(id: kept, title: "keep", pinned: false)))
        await coordinator.corePlugin.flush()

        // Another device deletes one. The snapshot is non-empty, so absence is
        // real evidence rather than an unreadable store.
        try await coordinator.database.apply(writes: [], deletions: [doomed], as: NoteModel.self)

        await coordinator.rehydrate(into: store)

        #expect(store.notes[doomed] == nil)
        #expect(store.notes[kept] != nil)
        #expect(
            store.notes.changes.isEmpty,
            "the row is already gone from storage — recording a deletion would echo it back to CloudKit"
        )
    }

    @Test("a write drained during the fetch is not overwritten by the stored row")
    func dirtyWriteLandingDuringTheFetchSurvives() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "original", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: false)], deletions: [], as: NoteModel.self)

        // Lands after the flush and after the fetch — so it is in the writer's
        // pending buffers, and in neither the store's `changes` nor the batch
        // the flush already handed off. Only `pendingIDs` can see it.
        coordinator.duringReadPhase = { store.send(.add(Note(id: id, title: "typed just now", pinned: false))) }

        await coordinator.rehydrate(into: store)

        #expect(
            store.notes[id]?.title == "typed just now",
            "an unflushed local write outranks storage, however late it landed"
        )
    }

    @Test("a delete drained during the fetch is not resurrected")
    func dirtyDeleteLandingDuringTheFetchIsNotResurrected() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let other = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "doomed", pinned: false)))
        store.send(.add(Note(id: other, title: "other", pinned: false)))
        await coordinator.corePlugin.flush()

        // The delete is drained into the writer's buffers but not flushed, so
        // `changes.deletions` is already cleared and the row is still on disk.
        coordinator.duringReadPhase = { store.send(.remove(id)) }

        await coordinator.rehydrate(into: store)

        #expect(store.notes[id] == nil, "a drained-but-unflushed delete must not be resurrected by the merge")
    }

    // MARK: - Editing holds

    @Test("a held ID keeps its in-memory value when a remote edit lands")
    func heldEntityIsNotOverwritten() async throws {
        // The store knows nothing about this entity — the edit under the
        // cursor was never dispatched. Without the hold this is exactly
        // `rehydrateSurfacesRemoteEdit`, and the remote title wins.
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "half-typed", pinned: false)))
        await coordinator.corePlugin.flush()

        coordinator.editing.hold(id)
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: true)], deletions: [],
            as: NoteModel.self)

        await coordinator.rehydrate(into: store)

        #expect(store.notes[id]?.title == "half-typed")
        #expect(store.notes[id]?.pinned == false)
    }

    @Test("a held ID is not removed by a remote deletion")
    func heldEntitySurvivesARemoteDeletion() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let held = UUID()
        let other = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: held, title: "being edited", pinned: false)))
        store.send(.add(Note(id: other, title: "keep", pinned: false)))
        await coordinator.corePlugin.flush()

        coordinator.editing.hold(held)
        // The snapshot stays non-empty, so absence really is evidence here.
        try await coordinator.database.apply(writes: [], deletions: [held], as: NoteModel.self)

        await coordinator.rehydrate(into: store)

        #expect(store.notes[held] != nil, "a row under the cursor is not pulled out from under it")
        #expect(store.notes[other] != nil)
    }

    @Test("releasing the hold lets the next merge apply the remote change")
    func releasingAHoldLetsTheRemoteValueLand() async throws {
        // A hold defers, it does not veto. This is what keeps a leaked hold to
        // a stale row rather than a permanently divergent one.
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "half-typed", pinned: false)))
        await coordinator.corePlugin.flush()

        coordinator.editing.hold(id)
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: true)], deletions: [],
            as: NoteModel.self)
        await coordinator.rehydrate(into: store)
        #expect(store.notes[id]?.title == "half-typed")

        coordinator.editing.release(id)
        await coordinator.rehydrate(into: store)

        #expect(store.notes[id]?.title == "edited elsewhere", "the deferred change lands on the next tick")
    }

    @Test("a hold protects only its own ID")
    func aHoldDoesNotProtectItsNeighbours() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let held = UUID()
        let free = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: held, title: "original", pinned: false)))
        store.send(.add(Note(id: free, title: "original", pinned: false)))
        await coordinator.corePlugin.flush()

        coordinator.editing.hold(held)
        try await coordinator.database.apply(
            writes: [
                Note(id: held, title: "edited elsewhere", pinned: false),
                Note(id: free, title: "edited elsewhere", pinned: false),
            ],
            deletions: [],
            as: NoteModel.self)

        await coordinator.rehydrate(into: store)

        #expect(store.notes[held]?.title == "original")
        #expect(store.notes[free]?.title == "edited elsewhere", "remote-wins stays on everywhere else")
    }

    // MARK: - Policies

    @Test("preferInMemory restores additive-only behaviour")
    func preferInMemoryKeepsMemoryAuthoritative() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30), mergePolicy: .preferInMemory)
        let edited = UUID()
        let doomed = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: edited, title: "original", pinned: false)))
        store.send(.add(Note(id: doomed, title: "doomed", pinned: false)))
        await coordinator.corePlugin.flush()

        try await coordinator.database.apply(
            writes: [Note(id: edited, title: "edited elsewhere", pinned: false)],
            deletions: [doomed],
            as: NoteModel.self)

        await coordinator.rehydrate(into: store)

        #expect(store.notes[edited]?.title == "original", "in-memory wins for every ID already held")
        #expect(store.notes[doomed] != nil, "and nothing is ever removed")
    }

    @Test("a per-entity policy narrows the coordinator default")
    func perEntityPolicyNarrowsTheDefault() async throws {
        let coordinator = try makeNotesCoordinator(
            debounce: .seconds(30), mergePolicy: .preferRemote, entityPolicy: .preferInMemory)
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "original", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: false)], deletions: [], as: NoteModel.self)

        await coordinator.rehydrate(into: store)

        #expect(store.notes[id]?.title == "original")
    }

    @Test("a call-site policy override can only narrow, never widen")
    func policyOverrideOnlyNarrows() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30), mergePolicy: .preferInMemory)
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "original", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: false)], deletions: [], as: NoteModel.self)

        // Asking for more authority than the coordinator was configured with
        // must not grant it.
        await coordinator.rehydrate(into: store, policy: .preferRemote)

        #expect(store.notes[id]?.title == "original")
    }

    @Test("preferRemoteAdditive surfaces remote edits but never removes")
    func preferRemoteAdditiveKeepsMissingRows() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let edited = UUID()
        let absent = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: edited, title: "original", pinned: false)))
        store.send(.add(Note(id: absent, title: "absent from the new store", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: edited, title: "edited elsewhere", pinned: false)],
            deletions: [absent],
            as: NoteModel.self)

        await coordinator.rehydrate(into: store, policy: .preferRemoteAdditive)

        #expect(store.notes[edited]?.title == "edited elsewhere")
        #expect(store.notes[absent] != nil, "absence carries no information under this policy")
    }

    @Test("rehydrate flushes first, so an unflushed local delete is not resurrected")
    func rehydrateDoesNotResurrectUnflushedDelete() async throws {
        // Large debounce so the scheduled flush never fires on its own during the
        // test — the pending delete stays buffered until rehydrate flushes it.
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let keep = UUID()
        let doomed = UUID()
        let store = makeNotesStore(coordinator)

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
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let diskRow = Note(id: UUID(), title: "disk", pinned: false)
        try await coordinator.database.apply(writes: [diskRow], deletions: [], as: NoteModel.self)
        let store = makeNotesStore(coordinator)

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
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let store = makeNotesStore(coordinator)

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
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let disk = Note(id: UUID(), title: "disk", pinned: false)
        try await coordinator.database.apply(writes: [disk], deletions: [], as: NoteModel.self)

        var initial = NotesState()
        initial.notes[UUID()] = Note(id: UUID(), title: "stale", pinned: false)
        initial.notes.resetChanges()
        let store = makeNotesStore(coordinator, initialState: initial)

        // `ui` is not a registered entity, and this dispatch lands mid-read.
        coordinator.duringReadPhase = { store.send(.setSearchText("typed")) }

        await coordinator.hydrate(into: store)

        #expect(store.notes.values == [disk], "registered entities are replaced on first load")
        #expect(store.ui.searchText == "typed", "unregistered slices survive, including concurrent edits")
    }
}
