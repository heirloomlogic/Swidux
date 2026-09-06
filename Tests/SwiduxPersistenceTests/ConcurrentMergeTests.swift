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
