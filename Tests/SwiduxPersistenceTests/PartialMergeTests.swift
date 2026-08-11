//
//  PartialMergeTests.swift
//  SwiduxPersistenceTests
//
//  `mergeRemote(into:ids:deleted:)` — the O(k) counterpart to `rehydrate`, for a
//  caller that already knows which rows changed. The guarantees `rehydrate`
//  makes have to hold here too; what differs is that absence proves nothing, so
//  a deletion has to be named rather than inferred.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Helpers

/// A coordinator holding one flushed note that the app has declared it is
/// editing — the state every carry-over test starts from.
///
/// The hold is the only thing that can withhold anything here: memory and
/// storage agree and nothing is pending, so a deferral in these tests is never
/// some other exemption wearing a hold's clothes. No watermark is established
/// either, so nothing falls back to a full read that would deliver a row the
/// narrow path was supposed to owe.
@MainActor
private func makeHeldNote() async throws -> (
    coordinator: PersistenceCoordinator<NotesState, NotesAction>,
    store: Store<NotesState, NotesAction>, id: UUID
) {
    let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
    let id = UUID()
    let store = makeNotesStore(coordinator)
    store.send(.add(Note(id: id, title: "being edited", pinned: false)))
    await coordinator.corePlugin.flush()
    coordinator.editing.hold(id)
    return (coordinator, store, id)
}

@Suite("PersistenceCoordinator.mergeRemote")
@MainActor
struct PartialMergeTests {
    // MARK: - Partial scope

    @Test("a remote edit to a named ID surfaces, and nothing else is read or touched")
    func mergeRemoteRefreshesOnlyNamedIDs() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let refreshed = UUID()
        let untouched = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: refreshed, title: "stale", pinned: false)))
        store.send(.add(Note(id: untouched, title: "untouched", pinned: false)))
        await coordinator.corePlugin.flush()

        // Another device edits both rows. Only one is named.
        try await coordinator.database.apply(
            writes: [
                Note(id: refreshed, title: "edited elsewhere", pinned: true),
                Note(id: untouched, title: "also edited elsewhere", pinned: true),
            ],
            deletions: [],
            as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [refreshed])

        #expect(store.notes[refreshed]?.title == "edited elsewhere")
        #expect(
            store.notes[untouched]?.title == "untouched",
            "an ID that wasn't named was not read, so its stored value must not land"
        )
    }

    @Test("an ID absent from the fetch is not removed — it wasn't asked about")
    func mergeRemoteNeverInfersDeletionFromAbsence() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let live = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: live, title: "live", pinned: false)))
        await coordinator.corePlugin.flush()

        // Named, but the row is gone from disk — and no deletion is declared.
        // The full-table merge would infer one; a partial merge must not.
        try await coordinator.database.apply(writes: [], deletions: [live], as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [live])

        #expect(
            store.notes[live] != nil,
            "inferring deletion from a partial snapshot is how the first merge wipes the table"
        )
    }

    @Test("naming an ID no registered entity holds changes nothing")
    func mergeRemoteToleratesUnknownIDs() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let kept = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: kept, title: "kept", pinned: false)))
        await coordinator.corePlugin.flush()

        await coordinator.mergeRemote(into: store, ids: [UUID()], deleted: [UUID()])

        #expect(store.notes[kept]?.title == "kept")
        #expect(store.notes.changes.isEmpty)
    }

    @Test("merging nothing is a no-op, not an empty-snapshot wipe")
    func mergeRemoteOfNothingChangesNothing() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let kept = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: kept, title: "kept", pinned: false)))
        await coordinator.corePlugin.flush()

        await coordinator.mergeRemote(into: store, ids: [])

        #expect(store.notes[kept] != nil)
    }

    @Test("a partial merge leaves unregistered slices alone")
    func mergeRemotePreservesOtherSlices() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "note", pinned: false)))
        store.send(.setSearchText("typed into the search box"))
        await coordinator.corePlugin.flush()

        await coordinator.mergeRemote(into: store, ids: [id])

        #expect(store.ui.searchText == "typed into the search box")
    }

    // MARK: - Declared deletions

    @Test("a declared deletion removes the row without echoing it back as a local one")
    func mergeRemoteAppliesDeclaredDeletion() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let doomed = UUID()
        let kept = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: doomed, title: "doomed", pinned: false)))
        store.send(.add(Note(id: kept, title: "keep", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(writes: [], deletions: [doomed], as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [], deleted: [doomed])

        #expect(store.notes[doomed] == nil)
        #expect(store.notes[kept] != nil)
        #expect(
            store.notes.changes.isEmpty,
            "the row is already gone from storage — recording a deletion would echo it back to CloudKit"
        )
        #expect(
            store.notes.remotelyRemovedIDs.contains(doomed),
            "a remote deletion has to outlive the undo snapshots taken before it"
        )
    }

    @Test("a declared deletion is ignored when the row is still on disk")
    func mergeRemoteLetsResurrectionOutrankATombstone() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let contested = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: contested, title: "local", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: contested, title: "restored elsewhere", pinned: false)],
            deletions: [], as: NoteModel.self)

        // Declared deleted *and* present: the live row is positive evidence,
        // the tombstone can be stale.
        await coordinator.mergeRemote(into: store, ids: [contested], deleted: [contested])

        #expect(store.notes[contested]?.title == "restored elsewhere")
        #expect(store.notes.remotelyRemovedIDs.isEmpty)
    }

    @Test("a declared deletion is not the last-entity special case a full merge has")
    func mergeRemoteCanRemoveTheLastEntity() async throws {
        // `rehydrate` refuses to act on an empty snapshot, so the last row can't
        // be removed remotely until relaunch. A named deletion carries its own
        // evidence, so that limit doesn't apply here.
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let only = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: only, title: "the last one", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(writes: [], deletions: [only], as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [], deleted: [only])

        #expect(store.notes.isEmpty)
    }

    // MARK: - Local intent still wins

    @Test("a write drained during the fetch is not overwritten by the stored row")
    func dirtyWriteLandingDuringTheFetchSurvives() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "original", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: false)], deletions: [],
            as: NoteModel.self)

        // Lands after the flush and after the fetch — visible only to
        // `StateWriter.pendingIDs`.
        coordinator.duringReadPhase = {
            store.send(.add(Note(id: id, title: "typed just now", pinned: false)))
        }

        await coordinator.mergeRemote(into: store, ids: [id])

        #expect(
            store.notes[id]?.title == "typed just now",
            "an unflushed local write outranks storage, however late it landed"
        )
    }

    @Test("a delete drained during the fetch is not resurrected")
    func dirtyDeleteLandingDuringTheFetchIsNotResurrected() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "doomed", pinned: false)))
        await coordinator.corePlugin.flush()

        coordinator.duringReadPhase = { store.send(.remove(id)) }

        await coordinator.mergeRemote(into: store, ids: [id])

        #expect(store.notes[id] == nil, "the row is on disk, but the local side has already deleted it")
    }

    @Test("a declared deletion never removes a row with an unflushed local write")
    func declaredDeletionYieldsToPendingWrite() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "typed but not saved", pinned: false)))

        // Never flushed: the write is still in the store's own `changes`.
        await coordinator.mergeRemote(into: store, ids: [id], deleted: [id])

        #expect(store.notes[id]?.title == "typed but not saved")
    }

    @Test("mergeRemote flushes first, so it can't read a stale row for a just-edited entity")
    func mergeRemoteFlushesFirst() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "v1", pinned: false)))
        await coordinator.corePlugin.flush()
        store.send(.add(Note(id: id, title: "v2 — buffered", pinned: false)))

        await coordinator.mergeRemote(into: store, ids: [id])

        #expect(store.notes[id]?.title == "v2 — buffered")
        let onDisk = try await coordinator.database.fetch(ids: [id], of: Note.self)
        #expect(onDisk.first?.title == "v2 — buffered", "the flush must have run before the read")
    }

    // MARK: - Editing holds

    @Test("a held ID keeps its in-memory value when a remote edit lands")
    func heldEntityIsNotOverwritten() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "half-typed", pinned: false)))
        await coordinator.corePlugin.flush()

        coordinator.editing.hold(id)
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: true)], deletions: [],
            as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [id])

        #expect(store.notes[id]?.title == "half-typed")
        #expect(store.notes[id]?.pinned == false)
    }

    @Test("a held ID is not removed by a declared deletion")
    func heldEntitySurvivesADeclaredDeletion() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let held = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: held, title: "being edited", pinned: false)))
        await coordinator.corePlugin.flush()

        coordinator.editing.hold(held)
        try await coordinator.database.apply(writes: [], deletions: [held], as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [], deleted: [held])

        #expect(store.notes[held] != nil, "a row under the cursor is not pulled out from under it")
    }

    @Test("a hold that actually withheld something is reported")
    func withheldHoldIsReported() async throws {
        let diagnostics = SendableBox<[PersistenceDiagnostic]>([])
        let coordinator = try makeNotesCoordinator(
            debounce: .seconds(30),
            onDiagnostic: { diagnostic in diagnostics.withValue { $0.append(diagnostic) } })
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "half-typed", pinned: false)))
        await coordinator.corePlugin.flush()

        coordinator.editing.hold(id)
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "edited elsewhere", pinned: false)], deletions: [],
            as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [id])

        #expect(
            diagnostics.value.contains(.mergeWithheld(entityType: "Note", ids: [id])),
            "a hold that cost a remote edit is exactly the leak an app needs to hear about"
        )
    }

    @Test("a hold that cost nothing is not reported")
    func unremarkableHoldIsSilent() async throws {
        let diagnostics = SendableBox<[PersistenceDiagnostic]>([])
        let coordinator = try makeNotesCoordinator(
            debounce: .seconds(30),
            onDiagnostic: { diagnostic in diagnostics.withValue { $0.append(diagnostic) } })
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "unchanged", pinned: false)))
        await coordinator.corePlugin.flush()
        coordinator.editing.hold(id)

        // The stored row matches, so the hold withheld nothing. Reporting one
        // per tick would drown the channel.
        await coordinator.mergeRemote(into: store, ids: [id])

        #expect(!diagnostics.value.contains { $0.kind == .mergeWithheld })
    }

    // MARK: - Policy

    @Test("preferInMemory keeps memory authoritative and ignores a declared deletion")
    func preferInMemoryIgnoresRemoteAuthority() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30), mergePolicy: .preferInMemory)
        let edited = UUID()
        let doomed = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: edited, title: "mine", pinned: false)))
        store.send(.add(Note(id: doomed, title: "also mine", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: edited, title: "theirs", pinned: false)],
            deletions: [doomed], as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [edited], deleted: [doomed])

        #expect(store.notes[edited]?.title == "mine")
        #expect(store.notes[doomed] != nil)
    }

    @Test("preferInMemory still absorbs a row it has never seen")
    func preferInMemoryStillInsertsNewRows() async throws {
        // "In-memory wins" is about IDs already held. A row that arrived from
        // elsewhere has no in-memory value to defend, so it lands — which is
        // what makes the policy *additive* rather than frozen.
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30), mergePolicy: .preferInMemory)
        let newcomer = UUID()
        let store = makeNotesStore(coordinator)
        try await coordinator.database.apply(
            writes: [Note(id: newcomer, title: "from another device", pinned: false)],
            deletions: [], as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [newcomer])

        #expect(store.notes[newcomer]?.title == "from another device")
    }

    @Test("preferRemoteAdditive surfaces the edit but refuses the deletion")
    func preferRemoteAdditiveKeepsDeclaredDeletions() async throws {
        let coordinator = try makeNotesCoordinator(
            debounce: .seconds(30), mergePolicy: .preferRemoteAdditive)
        let edited = UUID()
        let doomed = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: edited, title: "mine", pinned: false)))
        store.send(.add(Note(id: doomed, title: "also mine", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: edited, title: "theirs", pinned: false)],
            deletions: [doomed], as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [edited], deleted: [doomed])

        #expect(store.notes[edited]?.title == "theirs")
        #expect(store.notes[doomed] != nil, "removesMissingEntities is off, so no removal is authorised")
    }

    @Test("a call-site policy override can only narrow, never widen")
    func policyOverrideOnlyNarrows() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30), mergePolicy: .preferInMemory)
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "mine", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "theirs", pinned: false)], deletions: [], as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [id], policy: .preferRemote)

        #expect(store.notes[id]?.title == "mine", "an override composes by narrowing — it cannot grant authority")
    }

    @Test("a per-entity policy narrows the coordinator default")
    func perEntityPolicyNarrowsTheDefault() async throws {
        let coordinator = try makeNotesCoordinator(
            debounce: .seconds(30), mergePolicy: .preferRemote, entityPolicy: .preferInMemory)
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "mine", pinned: false)))
        await coordinator.corePlugin.flush()
        try await coordinator.database.apply(
            writes: [Note(id: id, title: "theirs", pinned: false)], deletions: [], as: NoteModel.self)

        await coordinator.mergeRemote(into: store, ids: [id])

        #expect(store.notes[id]?.title == "mine")
    }

    // MARK: - Duplicates

    @Test("duplicate rows collapse on the partial path and are reported")
    func partialMergeCollapsesAndReportsDuplicates() async throws {
        let diagnostics = SendableBox<[PersistenceDiagnostic]>([])
        let container = try makeNotesContainer()
        let coordinator = try makeNotesCoordinator(
            container: container,
            debounce: .seconds(30),
            onDiagnostic: { diagnostic in diagnostics.withValue { $0.append(diagnostic) } })
        let id = UUID()
        let store = makeNotesStore(coordinator)
        try seedDuplicates(container, id: id, title: "dup", count: 3)

        await coordinator.mergeRemote(into: store, ids: [id])

        #expect(store.notes[id]?.title == "dup")
        #expect(store.notes.count == 1, "an EntityStore cannot represent duplicates")
        #expect(diagnostics.value.contains(.duplicateRowsCollapsed(entityType: "Note", count: 2)))
        #expect(try rawNoteRows(container).count == 3, "collapsing on read must not delete anything on disk")
    }

    // MARK: - Carrying deferrals forward

    @Test("a deferred edit is re-offered by a later tick that names nothing")
    func aWithheldEditIsReOfferedWithoutANewSignal() async throws {
        let (coordinator, store, held) = try await makeHeldNote()

        try await remoteWrite(coordinator, writes: [Note(id: held, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeRemote(into: store, ids: [held])
        #expect(store.notes[held]?.title == "being edited", "a hold defers a remote change")

        // The signal that named this row is spent, and releasing a hold writes no
        // transaction of its own — so a tick naming *nothing* is the only thing
        // left that can deliver it.
        coordinator.editing.release(held)
        await coordinator.mergeRemote(into: store, ids: [])

        #expect(
            store.notes[held]?.title == "edited elsewhere",
            "a hold defers a remote change; it does not veto one")
    }

    @Test("a deferred deletion is re-offered by a later tick that names nothing")
    func aWithheldDeletionIsReOfferedWithoutANewSignal() async throws {
        let (coordinator, store, held) = try await makeHeldNote()

        try await remoteWrite(coordinator, deletions: [held])
        await coordinator.mergeRemote(into: store, ids: [], deleted: [held])
        #expect(store.notes[held] != nil, "a row under the cursor is not pulled out from under it")

        // A deferred deletion has no row left to re-read, so re-offering it means
        // declaring it again — which is why the debt records *which way* a row
        // was withheld rather than only that it was.
        coordinator.editing.release(held)
        await coordinator.mergeRemote(into: store, ids: [])

        #expect(store.notes[held] == nil, "a deferred deletion is still owed")
    }

    @Test("a deferral from mergeRemote is delivered by the watermark path too")
    func aWithheldRowCrossesToMergeChanges() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let held = UUID()
        let store = makeNotesStore(coordinator)
        store.send(.add(Note(id: held, title: "being edited", pinned: false)))
        await coordinator.corePlugin.flush()
        // Anchors the session, so the tick below narrows rather than falling back
        // to a full read that would have delivered the row regardless.
        await coordinator.mergeChanges(into: store)

        coordinator.editing.hold(held)
        try await remoteWrite(coordinator, writes: [Note(id: held, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeRemote(into: store, ids: [held])
        #expect(store.notes[held]?.title == "being edited")

        // Move the watermark past the window that recorded the edit, as any
        // later tick would. History will never name this row again, so the debt
        // is now the only thing that still knows about it.
        let generation = coordinator.handle.anchor.generation
        let spent = try #require(await coordinator.database.currentHistoryToken())
        coordinator.handle.installAnchor(watermark: spent, carryOver: nil, ifGeneration: generation)

        coordinator.editing.release(held)
        await coordinator.mergeChanges(into: store)

        #expect(
            store.notes[held]?.title == "edited elsewhere",
            "one debt, whichever path recorded it and whichever path settles it")
    }

    @Test("a tick for an unrelated ID does not swallow what is already owed")
    func anUnrelatedTickDoesNotClobberTheDebt() async throws {
        let (coordinator, store, held) = try await makeHeldNote()
        let unrelated = UUID()
        store.send(.add(Note(id: unrelated, title: "not being edited", pinned: false)))
        await coordinator.corePlugin.flush()

        try await remoteWrite(coordinator, writes: [Note(id: held, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeRemote(into: store, ids: [held])

        // One debt slot serves every path, so a tick that was never offered the
        // held row must not record an empty set over it.
        try await remoteWrite(coordinator, writes: [Note(id: unrelated, title: "theirs", pinned: false)])
        await coordinator.mergeRemote(into: store, ids: [unrelated])
        #expect(store.notes[unrelated]?.title == "theirs")

        coordinator.editing.release(held)
        await coordinator.mergeRemote(into: store, ids: [])

        #expect(store.notes[held]?.title == "edited elsewhere", "the debt survived a tick that never named it")
    }

    @Test("a session that never established a watermark still records what it owes")
    func anUnanchoredSessionRecordsTheDebt() async throws {
        // `mergeChanges` is never called here, so nothing ever anchors. A debt
        // that could only hang off a watermark would be dropped on the floor.
        let (coordinator, store, held) = try await makeHeldNote()

        try await remoteWrite(coordinator, writes: [Note(id: held, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeRemote(into: store, ids: [held])

        #expect(coordinator.handle.anchor.token == nil, "nothing in this test anchors a window")
        #expect(
            !coordinator.handle.anchor.carryOver.isEmpty,
            "the debt is about identities, not about a window — only the generation has to match")
    }

    @Test("swapping the database discards a debt mergeRemote recorded")
    func swappingTheDatabaseDiscardsTheDebt() async throws {
        let (coordinator, store, held) = try await makeHeldNote()

        try await remoteWrite(coordinator, writes: [Note(id: held, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeRemote(into: store, ids: [held])
        #expect(!coordinator.handle.anchor.carryOver.isEmpty, "there has to be a debt to discard")

        coordinator.handle.db = EntityDB(modelContainer: try makeNotesContainer())

        #expect(
            coordinator.handle.anchor.carryOver.isEmpty,
            "identities resolved against one store say nothing about another")
    }

    @Test("rehydrate still records nothing")
    func rehydrateLeavesTheDebtAlone() async throws {
        let (coordinator, store, held) = try await makeHeldNote()

        try await remoteWrite(coordinator, writes: [Note(id: held, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeRemote(into: store, ids: [held])
        let owed = coordinator.handle.anchor.carryOver.reading(for: "NoteModel")
        #expect(owed == [held], "there has to be a debt for rehydrate to leave alone")

        await coordinator.rehydrate(into: store)

        #expect(
            coordinator.handle.anchor.carryOver.reading(for: "NoteModel") == owed,
            "a whole-table read re-offers everything next time, so it has no accounting to keep")
    }

    @Test("a settled debt clears, so nothing re-offers forever")
    func aSettledDebtClears() async throws {
        let (coordinator, store, held) = try await makeHeldNote()

        try await remoteWrite(coordinator, writes: [Note(id: held, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeRemote(into: store, ids: [held])
        #expect(!coordinator.handle.anchor.carryOver.isEmpty)

        coordinator.editing.release(held)
        await coordinator.mergeRemote(into: store, ids: [])

        #expect(
            coordinator.handle.anchor.carryOver.isEmpty,
            "a debt that outlived the hold that caused it would be re-read on every tick")
    }
}
