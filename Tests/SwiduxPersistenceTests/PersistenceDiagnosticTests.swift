//
//  PersistenceDiagnosticTests.swift
//  SwiduxPersistenceTests
//
//  Cover for #61: the non-failure diagnostic channel. `onFailure` is correctly
//  scoped to failures, so conditions that are *not* failures — duplicate rows
//  collapsed on read, a probable dispatch loop, the accumulated set of writes
//  that never reached disk — had nowhere to go but Console.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

@Suite("Persistence diagnostics")
@MainActor
struct PersistenceDiagnosticTests {
    private typealias DiagnosticLog = SendableBox<[PersistenceDiagnostic]>

    /// A coordinator that records everything it reports, over a container
    /// pre-seeded with `duplicates + 1` rows sharing one ID when asked.
    private func makeRecording(
        duplicates: Int = 0,
        collapse: (@Sendable ([Note]) -> [Note])? = nil,
        debounce: Duration = .milliseconds(10),
        container: ModelContainer? = nil
    ) throws -> (PersistenceCoordinator<NotesState, NotesAction>, DiagnosticLog) {
        let container = try container ?? makeNotesContainer()
        if duplicates > 0 {
            try seedDuplicates(container, id: UUID(), count: duplicates + 1)
        }
        let log = DiagnosticLog([])
        let coordinator = try makeNotesCoordinator(
            container: container,
            debounce: debounce,
            collapse: collapse,
            onDiagnostic: { diagnostic in log.withValue { $0.append(diagnostic) } }
        )
        return (coordinator, log)
    }

    // MARK: - Duplicate rows collapsed on read

    @Test("Duplicate rows collapsed on hydrate are reported with their count")
    func hydrateReportsDuplicates() async throws {
        let (coordinator, log) = try makeRecording(duplicates: 2)

        var state = NotesState()
        await coordinator.hydrate(into: &state)

        #expect(log.value == [.duplicateRowsCollapsed(entityType: "Note", count: 2)])
        #expect(state.notes.count == 1, "the read still collapses — the diagnostic is additional")
    }

    @Test("A table with no duplicates reports nothing")
    func cleanReadIsSilent() async throws {
        let container = try makeNotesContainer()
        try seedNotes(container, [Note(id: UUID(), title: "a", pinned: false)])
        let (coordinator, log) = try makeRecording(container: container)

        var state = NotesState()
        await coordinator.hydrate(into: &state)

        #expect(log.value.isEmpty)
    }

    @Test("Duplicates are reported even when a collapse resolver is registered")
    func collapseRegisteredStillReportsDuplicates() async throws {
        // Rows sharing a *surviving* ID are converged, not removed — see
        // `EntityDB.collapseDuplicates`. So a registered collapse does not make
        // the duplicates disappear, and staying silent here would be untrue.
        let (coordinator, log) = try makeRecording(duplicates: 1, collapse: { $0 })

        var state = NotesState()
        await coordinator.hydrate(into: &state)

        #expect(log.value == [.duplicateRowsCollapsed(entityType: "Note", count: 1)])
    }

    @Test("Re-hydration reports duplicates on the merge read path too")
    func rehydrateReportsDuplicates() async throws {
        let (coordinator, log) = try makeRecording(duplicates: 1)
        let store = makeNotesStore(coordinator)

        await coordinator.rehydrate(into: store)

        #expect(log.value == [.duplicateRowsCollapsed(entityType: "Note", count: 1)])
    }

    @Test("The public fetchAll read path reports duplicates")
    func publicFetchAllReportsDuplicates() async throws {
        let (coordinator, log) = try makeRecording(duplicates: 3)

        let rows = try await coordinator.fetchAll(of: Note.self)

        #expect(rows.count == 1)
        #expect(log.value == [.duplicateRowsCollapsed(entityType: "Note", count: 3)])
    }

    // MARK: - Writes that never reached disk

    @Test("A save that fails reports the accumulated unpersisted IDs")
    func failedSaveReportsUnpersistedIDs() async throws {
        let log = DiagnosticLog([])
        let id = UUID()
        let coordinator = try makeNotesCoordinator(
            container: makeUnwritableNotesContainer(),
            retry: .never,
            onDiagnostic: { diagnostic in log.withValue { $0.append(diagnostic) } }
        )

        var state = NotesState()
        state.notes[id] = Note(id: id, title: "never lands", pinned: false)
        coordinator.corePlugin.drainAndScheduleFlush(&state)

        try await poll(until: { !log.value.isEmpty }, timeout: .seconds(5))

        #expect(log.value == [.writesUnpersisted(entityType: "Note", ids: [id])])
    }

    // MARK: - Remote changes withheld by an editing hold

    /// A store holding one flushed note, plus the coordinator's diagnostic log.
    /// Flushed on purpose: nothing the *store* knows about protects the row, so
    /// a hold is the only thing that can withhold anything.
    private func makeHeldNote() async throws -> (
        PersistenceCoordinator<NotesState, NotesAction>, Store<NotesState, NotesAction>, UUID,
        DiagnosticLog
    ) {
        let (coordinator, log) = try makeRecording(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)
        store.send(.add(Note(id: id, title: "half-typed", pinned: false)))
        await coordinator.corePlugin.flush()
        coordinator.editing.hold(id)
        return (coordinator, store, id, log)
    }

    @Test("a remote edit withheld by an editing hold is reported")
    func withheldRemoteEditIsReported() async throws {
        // A hold is the one exemption an app can leak, so it is the one that
        // has to be visible. Otherwise it presents as a row that mysteriously
        // stopped syncing.
        let (coordinator, store, id, log) = try await makeHeldNote()

        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: true)], deletions: [],
            as: NoteModel.self)
        await coordinator.rehydrate(into: store)

        #expect(log.value == [.mergeWithheld(entityType: "Note", ids: [id])])
    }

    @Test("a remote deletion withheld by an editing hold is reported")
    func withheldRemoteDeletionIsReported() async throws {
        let (coordinator, store, id, log) = try await makeHeldNote()
        // A second row keeps the snapshot non-empty, so absence is evidence.
        store.send(.add(Note(id: UUID(), title: "keep", pinned: false)))
        await coordinator.corePlugin.flush()

        try await coordinator.database.apply(writes: [], deletions: [id], as: NoteModel.self)
        await coordinator.rehydrate(into: store)

        #expect(log.value == [.mergeWithheld(entityType: "Note", ids: [id])])
    }

    @Test("a hold over a row nobody changed remotely reports nothing")
    func heldButUnchangedRowIsSilent() async throws {
        // The hold is in force on every tick an editor is open. Reporting one
        // per tick would drown the channel and tell an app nothing.
        let (coordinator, store, _, log) = try await makeHeldNote()

        await coordinator.rehydrate(into: store)

        #expect(log.value.isEmpty)
    }

    @Test("an ID the store already protects is not reported as withheld by a hold")
    func dirtyIDIsNotAttributedToTheHold() async throws {
        // An un-flushed write is exempt with or without a hold. Attributing it
        // to the hold would point a leak hunt at the wrong thing.
        let (coordinator, log) = try makeRecording(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "original", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: true)], deletions: [],
            as: NoteModel.self)

        coordinator.editing.hold(id)
        // Drained into the writer's buffers after the flush, so `pendingIDs`
        // covers this ID on its own — the hold is redundant here.
        coordinator.duringReadPhase = {
            store.send(.add(Note(id: id, title: "local edit", pinned: false)))
        }

        await coordinator.rehydrate(into: store)

        #expect(store.notes[id]?.title == "local edit")
        #expect(log.value.isEmpty)
    }

    // MARK: - Dispatch loop

    @Test("The core plugin's loop signal arrives as a diagnostic")
    func dispatchLoopIsReported() async throws {
        // The coordinator builds its plugin with the default threshold of 100,
        // so the burst has to actually cross it. Synchronous, so the debounce
        // can't fire part-way and reset the count.
        let (coordinator, log) = try makeRecording(debounce: .seconds(30))

        var state = NotesState()
        for index in 0..<102 {
            let note = Note(id: UUID(), title: "loop \(index)", pinned: false)
            state.notes[note.id] = note
            coordinator.corePlugin.drainAndScheduleFlush(&state)
        }

        #expect(log.value == [.possibleDispatchLoop(drainCount: 101)])
    }

    // MARK: - The default construction

    @Test("A nil handler leaves every read path working")
    func nilHandlerIsHarmless() async throws {
        // What almost every app uses: the diagnostic plumbing must not depend
        // on a handler being installed.
        let container = try makeNotesContainer()
        try seedDuplicates(container, id: UUID(), count: 2)

        let coordinator = try makeNotesCoordinator(container: container)
        var state = NotesState()
        await coordinator.hydrate(into: &state)

        #expect(state.notes.count == 1)
        #expect(try await coordinator.fetchAll(of: Note.self).count == 1)
    }

    @Test("A nil handler leaves the merge paths working, holds and all")
    func nilHandlerIsHarmlessAcrossAMerge() async throws {
        // The paths that now skip building a diagnostic nobody asked for: a
        // narrowed tick, and the hold inside it that withholds a row. Both still
        // have to do their real work, which is the merge and the carry-over.
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let held = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: held, title: "being edited", pinned: false)))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)

        coordinator.editing.hold(held)
        try await remoteWrite(coordinator, writes: [Note(id: held, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeChanges(into: store)
        #expect(store.notes[held]?.title == "being edited", "a hold defers a remote change")

        coordinator.editing.release(held)
        await coordinator.mergeChanges(into: store)
        #expect(store.notes[held]?.title == "edited elsewhere", "and the debt is still re-offered")
    }

    // MARK: - How a narrowed tick describes itself

    @Test("A merge that re-offered nothing describes itself as it always did")
    func descriptionOmitsAnEmptyCarryOver() {
        #expect(
            PersistenceDiagnostic.remoteChangesMerged(count: 3).description
                == "merged 3 changed row(s) from persistent history"
        )
    }

    @Test("A merge that re-offered a debt says so in its description")
    func descriptionNamesTheCarryOver() {
        // The one-line read of a leaked hold: everything merged was already owed.
        let described = PersistenceDiagnostic.remoteChangesMerged(count: 2, carriedOver: 2).description

        #expect(described.contains("2 re-offered"))
    }

    // MARK: - The ledger's own semantics

    @Test("The unpersisted ledger reports every change, including recovery to empty")
    func ledgerReportsChanges() {
        let ledger = UnpersistedIDs()
        let first = UUID()
        let second = UUID()

        #expect(ledger.markFailed([first]))
        #expect(ledger.markFailed([second]))
        #expect(ledger.markPersisted([first]))
        #expect(
            ledger.markPersisted([second]),
            "an app clearing a \"not saved\" banner needs the drain to empty, not just the growth"
        )
        #expect(ledger.ids.isEmpty)
    }

    @Test("The unpersisted ledger stays silent when nothing changed")
    func ledgerIsSilentOnNoOp() {
        let ledger = UnpersistedIDs()
        let id = UUID()

        #expect(ledger.markFailed([id]))
        #expect(!ledger.markFailed([id]), "a repeated failure on the same ID is not new information")
        #expect(!ledger.markPersisted([UUID()]))
        #expect(!ledger.markPersisted([]))
        #expect(ledger.ids == [id])
    }
}
