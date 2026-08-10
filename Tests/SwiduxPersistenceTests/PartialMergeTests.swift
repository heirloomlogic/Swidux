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
}
