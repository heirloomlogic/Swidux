import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

@Suite("Persistence merge ordering")
@MainActor
struct ConcurrentMergeTests {
    @Test("a suspended history merge cannot roll back a newer committed window")
    func olderHistoryReadCannotRollBackNewerMerge() async throws {
        let coordinator = try makeNotesCoordinator(historyRetention: nil)
        let store = makeNotesStore(coordinator)
        let id = UUID()
        try await remoteWrite(coordinator, writes: [Note(id: id, title: "initial", pinned: false)])
        await coordinator.mergeChanges(into: store)
        try await remoteWrite(coordinator, writes: [Note(id: id, title: "older", pinned: false)])
        let gate = MergeReadGate()
        coordinator.duringReadPhase = { await gate.pauseFirstCall() }
        let older = Task { await coordinator.mergeChanges(into: store) }
        await gate.waitUntilPaused()

        try await remoteWrite(coordinator, writes: [Note(id: id, title: "newer", pinned: false)])
        await coordinator.mergeChanges(into: store)
        let newestToken = coordinator.handle.anchor.token
        #expect(store.notes[id]?.title == "newer")
        await gate.release()
        await older.value

        #expect(store.notes[id]?.title == "newer")
        #expect(coordinator.handle.anchor.token == newestToken)
        await coordinator.mergeChanges(into: store)
        #expect(store.notes[id]?.title == "newer")
    }

    @Test("reads from a replaced database cannot mutate live state")
    func replacedDatabaseReadIsDiscarded() async throws {
        let coordinator = try makeNotesCoordinator(historyRetention: nil)
        let store = makeNotesStore(coordinator)
        let id = UUID()
        try await remoteWrite(coordinator, writes: [Note(id: id, title: "old database", pinned: false)])
        let gate = MergeReadGate()
        coordinator.duringReadPhase = { await gate.pauseFirstCall() }
        let older = Task { await coordinator.rehydrate(into: store) }
        await gate.waitUntilPaused()

        coordinator.handle.db = EntityDB(modelContainer: try makeNotesContainer())
        try await remoteWrite(coordinator, writes: [Note(id: id, title: "new database", pinned: false)])
        await coordinator.mergeChanges(into: store)
        let newestToken = coordinator.handle.anchor.token
        await gate.release()
        await older.value

        #expect(store.notes[id]?.title == "new database")
        #expect(coordinator.handle.anchor.token == newestToken)
    }

    @Test("a merge that read before a store hydration cannot fold its older rows over it")
    func olderMergeCannotRollBackAHydration() async throws {
        let coordinator = try makeNotesCoordinator(historyRetention: nil)
        let store = makeNotesStore(coordinator)
        let id = UUID()
        try await remoteWrite(coordinator, writes: [Note(id: id, title: "older", pinned: false)])
        let gate = MergeReadGate()
        coordinator.duringReadPhase = { await gate.pauseFirstCall() }
        // A remote-change observer started before hydration finished.
        let older = Task { await coordinator.rehydrate(into: store) }
        await gate.waitUntilPaused()

        try await remoteWrite(coordinator, writes: [Note(id: id, title: "newer", pinned: false)])
        await coordinator.hydrate(into: store)
        #expect(store.notes[id]?.title == "newer")
        await gate.release()
        await older.value

        #expect(store.notes[id]?.title == "newer", "a read older than the hydration was folded over it")
    }

    @Test("a merge that read before collapseDuplicates cannot put the losers back")
    func olderMergeCannotResurrectCollapsedLosers() async throws {
        let container = try makeNotesContainer()
        // Singletons: whatever else is on disk, only the lowest title survives.
        let coordinator = try makeNotesCoordinator(
            container: container, mergePolicy: .preferInMemory, historyRetention: nil,
            collapse: { rows in Array(rows.sorted { $0.title < $1.title }.prefix(1)) })
        let store = makeNotesStore(coordinator)
        let (keeper, loser) = (UUID(), UUID())
        try seedNotes(container, [Note(id: keeper, title: "a", pinned: false)])
        await coordinator.hydrate(into: store)
        try seedNotes(container, [Note(id: loser, title: "b", pinned: false)])

        let gate = MergeReadGate()
        coordinator.duringReadPhase = { await gate.pauseFirstCall() }
        let older = Task { await coordinator.mergeRemote(into: store, ids: [loser]) }
        await gate.waitUntilPaused()

        await coordinator.collapseDuplicates(into: store)
        #expect(store.notes[loser] == nil)
        await gate.release()
        await older.value

        #expect(store.notes[loser] == nil, "a read older than the collapse put the loser back in memory")
    }

    @Test("a collapse whose merge is discarded still removes its losers from memory")
    func aDiscardedCollapseStillRemovesItsLosers() async throws {
        let container = try makeNotesContainer()
        let coordinator = try makeNotesCoordinator(
            container: container, mergePolicy: .preferInMemory, historyRetention: nil,
            collapse: { rows in Array(rows.sorted { $0.title < $1.title }.prefix(1)) })
        let store = makeNotesStore(coordinator)
        let (keeper, loser) = (UUID(), UUID())
        try seedNotes(container, [Note(id: keeper, title: "a", pinned: false)])
        await coordinator.hydrate(into: store)
        // Created here as well as on another device: two singletons now.
        store.send(.add(Note(id: loser, title: "b", pinned: false)))
        await coordinator.corePlugin.flush()

        let gate = MergeReadGate()
        coordinator.duringReadPhase = { await gate.pauseFirstCall() }
        // The whole-table read deletes the loser on disk inside its read phase…
        let older = Task { await coordinator.rehydrate(into: store) }
        await gate.waitUntilPaused()
        // …and another merge commits meanwhile, so that read's fold is discarded.
        await coordinator.mergeRemote(into: store, ids: [])
        await gate.release()
        await older.value

        // The retry's collapse finds nothing left to remove, and under
        // preferInMemory absence removes nothing either.
        #expect(try rawNoteRows(container).map(\.id) == [keeper])
        #expect(store.notes[loser] == nil, "the loser lingers in memory, and an edit would re-upload it")
    }

    @Test("an overlapping caller-fed merge preserves distinct signals and newer debt")
    func overlappingPartialMergesPreserveSignalsAndDebt() async throws {
        let coordinator = try makeNotesCoordinator(historyRetention: nil)
        let store = makeNotesStore(coordinator)
        let shared = UUID()
        let olderOnly = UUID()
        let held = UUID()
        store.send(.add(Note(id: held, title: "local editor", pinned: false)))
        await coordinator.corePlugin.flush()
        try await remoteWrite(
            coordinator,
            writes: [
                Note(id: shared, title: "old shared", pinned: false),
                Note(id: olderOnly, title: "older signal", pinned: false),
                Note(id: held, title: "held remote", pinned: false),
            ])
        coordinator.editing.hold(held)
        let gate = MergeReadGate()
        coordinator.duringReadPhase = { await gate.pauseFirstCall() }
        let older = Task { await coordinator.mergeRemote(into: store, ids: [shared, olderOnly]) }
        await gate.waitUntilPaused()

        try await remoteWrite(coordinator, writes: [Note(id: shared, title: "new shared", pinned: false)])
        await coordinator.mergeRemote(into: store, ids: [shared, held])
        #expect(coordinator.handle.anchor.carryOver.reading(for: "NoteModel") == [held])
        await gate.release()
        await older.value

        #expect(store.notes[shared]?.title == "new shared")
        #expect(store.notes[olderOnly]?.title == "older signal")
        #expect(coordinator.handle.anchor.carryOver.reading(for: "NoteModel") == [held])
        coordinator.editing.release(held)
        await coordinator.mergeRemote(into: store, ids: [])
        #expect(store.notes[held]?.title == "held remote")
        #expect(coordinator.handle.anchor.carryOver.isEmpty)
    }
}

private actor MergeReadGate {
    private var hasPaused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func pauseFirstCall() async {
        guard !hasPaused else { return }
        hasPaused = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            arrival?.resume()
            arrival = nil
        }
    }

    func waitUntilPaused() async {
        if hasPaused { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
