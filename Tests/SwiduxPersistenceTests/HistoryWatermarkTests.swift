//
//  HistoryWatermarkTests.swift
//  SwiduxPersistenceTests
//
//  Cover for #74: `mergeChanges` narrows a remote-change tick to the rows
//  persistent history says changed, and falls back to a full re-hydration for
//  every window it cannot fully account for.
//
//  The fallbacks carry most of the weight here. A watermark consumes evidence
//  once, so anything this misses is missed for good — which is why every test
//  below that proves a fallback *ran* matters more than the ones proving the
//  fast path works.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Helpers

/// Runs the first tick, which has no watermark and so always re-reads
/// everything, leaving an anchor behind for the ticks the test actually cares
/// about.
@MainActor
private func establishWatermark(
    _ coordinator: PersistenceCoordinator<NotesState, NotesAction>,
    _ store: Store<NotesState, NotesAction>
) async {
    await coordinator.mergeChanges(into: store)
}

/// A coordinator and store holding one flushed note, already anchored — the
/// state almost every test here starts from.
@MainActor
private func makeAnchoredNote(
    title: String = "mine",
    container: ModelContainer? = nil,
    onDiagnostic: PersistenceDiagnosticHandler? = nil
) async throws -> (
    coordinator: PersistenceCoordinator<NotesState, NotesAction>,
    store: Store<NotesState, NotesAction>, id: UUID
) {
    let coordinator = try makeNotesCoordinator(
        container: container, debounce: .seconds(30), onDiagnostic: onDiagnostic)
    let id = UUID()
    let store = makeNotesStore(coordinator)
    store.send(.add(Note(id: id, title: title, pinned: false)))
    await coordinator.corePlugin.flush()
    await establishWatermark(coordinator, store)
    return (coordinator, store, id)
}

/// Holds `id`, lands a conflicting remote edit on it, and runs the tick that
/// defers that edit — leaving exactly one row owed and the hold still in force.
@MainActor
private func withholdARemoteEdit(
    _ coordinator: PersistenceCoordinator<NotesState, NotesAction>,
    _ store: Store<NotesState, NotesAction>,
    _ id: UUID
) async throws {
    coordinator.editing.hold(id)
    try await remoteWrite(coordinator, writes: [Note(id: id, title: "edited elsewhere", pinned: true)])
    await coordinator.mergeChanges(into: store)
}

/// Every reason a scan can refuse to answer. The seam throws in place of the
/// scan, so these prove the *escalation*, not the trigger — that a window the
/// scan gave up on is still fully merged, whatever gave up on it.
private let scanFailures: [any Error] = [
    SwiftDataError.historyTokenExpired,
    HistoryScanFailure.tokenExpired,
    HistoryScanFailure.fetchFailed("the store said no"),
    HistoryScanFailure.unidentifiedDeletion(entityName: "NoteModel"),
    HistoryScanFailure.unresolvedChanges(entityName: "NoteModel"),
    HistoryScanFailure.multipleStores,
]

// MARK: - The narrow path

@Suite("PersistenceCoordinator.mergeChanges")
@MainActor
struct HistoryWatermarkTests {
    @Test("a remote edit recorded in history surfaces")
    func surfacesARemoteEdit() async throws {
        let (coordinator, store, id) = try await makeAnchoredNote()

        try await remoteWrite(coordinator, writes: [Note(id: id, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id]?.title == "edited elsewhere")
    }

    @Test("a remote insert recorded in history surfaces")
    func surfacesARemoteInsert() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let store = makeNotesStore(coordinator)
        await establishWatermark(coordinator, store)

        let arrived = UUID()
        try await remoteWrite(coordinator, writes: [Note(id: arrived, title: "from a peer", pinned: false)])
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[arrived]?.title == "from a peer")
    }

    @Test("a remote deletion surfaces from its tombstone, without echoing back")
    func surfacesARemoteDeletion() async throws {
        let (coordinator, store, doomed) = try await makeAnchoredNote(title: "doomed")

        try await remoteWrite(coordinator, deletions: [doomed])
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[doomed] == nil, "a tombstone is positive evidence of deletion")
        #expect(
            store.notes.changes.isEmpty,
            "a deletion read from history must not be echoed back to storage as a local one"
        )
    }

    @Test("a deletion read from history can remove the last surviving row")
    func removesTheLastRow() async throws {
        let (coordinator, store, only) = try await makeAnchoredNote(title: "the only one")

        try await remoteWrite(coordinator, deletions: [only])
        await coordinator.mergeChanges(into: store)

        // The empty-snapshot guard blocks this on the full path, deliberately.
        // Tombstones are evidence an empty table isn't, so the narrow path can.
        #expect(store.notes.isEmpty)
    }

    @Test("a window with no transactions does nothing at all")
    func emptyWindowIsANoOp() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let (coordinator, store, kept) = try await makeAnchoredNote(
            title: "kept", onDiagnostic: onDiagnostic)
        log.clear()

        await coordinator.mergeChanges(into: store)

        #expect(store.notes[kept]?.title == "kept")
        #expect(log.value.isEmpty, "nothing changed, so there is nothing to merge and nothing to report")
    }

    @Test("only the changed rows are read — the rest of the table is never touched")
    func readsOnlyWhatChanged() async throws {
        let container = try makeNotesContainer()
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = try makeNotesCoordinator(
            container: container, debounce: .seconds(30), onDiagnostic: onDiagnostic)
        let edited = UUID()
        let duplicated = UUID()
        let store = makeNotesStore(coordinator)

        // Duplicate rows are the probe: any read that touches them collapses
        // them and says so. Seeded before the anchor, so they are behind the
        // watermark and no tick has reason to name them.
        try seedNotes(
            container,
            [
                Note(id: edited, title: "mine", pinned: false),
                Note(id: duplicated, title: "twin", pinned: false),
                Note(id: duplicated, title: "twin", pinned: true),
            ])

        await establishWatermark(coordinator, store)
        #expect(
            log.contains(.duplicateRowsCollapsed),
            "the anchoring full read must have seen the duplicates, or the probe proves nothing")
        log.clear()

        try await remoteWrite(coordinator, writes: [Note(id: edited, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[edited]?.title == "edited elsewhere")
        #expect(
            !log.contains(.duplicateRowsCollapsed),
            "reading the whole table again would have collapsed the duplicates a second time"
        )
        #expect(log.contains(.remoteChangesMerged))
    }

    // MARK: - Local intent still wins

    @Test("an unflushed local write outranks the remote change in the same window")
    func pendingLocalWriteWins() async throws {
        let (coordinator, store, id) = try await makeAnchoredNote()

        try await remoteWrite(coordinator, writes: [Note(id: id, title: "edited elsewhere", pinned: true)])
        // Dispatched but never flushed: local intent the merge must not clobber.
        store.send(.add(Note(id: id, title: "typed just now", pinned: false)))

        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id]?.title == "typed just now")
    }

    @Test("a write drained during the fetch is not overwritten by the stored row")
    func writeDrainedDuringTheFetchSurvives() async throws {
        let (coordinator, store, id) = try await makeAnchoredNote()

        try await remoteWrite(coordinator, writes: [Note(id: id, title: "edited elsewhere", pinned: true)])
        // Lands after the flush and after the fetch was issued — the window the
        // late-bound dirty read exists to cover.
        coordinator.duringReadPhase = { store.send(.add(Note(id: id, title: "typed mid-fetch", pinned: false))) }

        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id]?.title == "typed mid-fetch")
    }

    @Test("a locally deleted row is not resurrected by its own history")
    func doesNotResurrectALocalDelete() async throws {
        let (coordinator, store, id) = try await makeAnchoredNote(title: "doomed")

        store.send(.remove(id))
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id] == nil)
    }

    @Test("a local delete undone before the tick refutes its own tombstone")
    func anUndoneDeleteOutranksItsOwnTombstone() async throws {
        let (coordinator, store, id) = try await makeAnchoredNote(title: "kept after all")

        // Deleted and flushed, so history holds a tombstone naming it...
        store.send(.remove(id))
        await coordinator.corePlugin.flush()
        // ...then recreated. The row is back on disk by the time the tick reads,
        // which is exactly what refutes the tombstone the same tick found.
        store.send(.add(Note(id: id, title: "kept after all", pinned: false)))

        await coordinator.mergeChanges(into: store)

        #expect(
            store.notes[id] != nil,
            "a row storage still holds must outrank a tombstone for the same ID")
    }

    // MARK: - Fallbacks

    @Test("the first tick after launch re-reads everything")
    func firstTickReReadsEverything() async throws {
        let container = try makeNotesContainer()
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = try makeNotesCoordinator(
            container: container, debounce: .seconds(30), onDiagnostic: onDiagnostic)
        let store = makeNotesStore(coordinator)

        // On disk before the coordinator existed, so no transaction this session
        // names it. Only a full read can find it.
        try seedNotes(container, [Note(id: UUID(), title: "written before launch", pinned: false)])

        await coordinator.mergeChanges(into: store)

        #expect(store.notes.count == 1, "a narrow first tick would never have looked")
        #expect(log.fallbackReasons.contains("no watermark yet"))
    }

    @Test("a scan that gives up still re-reads everything", arguments: scanFailures)
    func aScanFailureReReadsEverything(error: any Error) async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let (coordinator, store, id) = try await makeAnchoredNote(onDiagnostic: onDiagnostic)
        log.clear()

        try await remoteWrite(coordinator, writes: [Note(id: id, title: "edited elsewhere", pinned: true)])
        coordinator.failNextHistoryScan = error

        await coordinator.mergeChanges(into: store)

        #expect(
            store.notes[id]?.title == "edited elsewhere",
            "the fallback is what makes losing the window survivable — it has to actually run")
        #expect(log.contains(.historyUnavailable))
        #expect(!log.contains(.remoteChangesMerged), "this tick did not narrow anything")
    }

    @Test("a scan failure is a diagnostic, not a data failure")
    func aScanFailureIsNotReportedAsAFailure() async throws {
        let failures = SendableBox<[PersistenceFailure]>([])
        let coordinator = try makeNotesCoordinator(
            debounce: .seconds(30),
            onFailure: { failure in failures.withValue { $0.append(failure) } })
        let store = makeNotesStore(coordinator)

        await establishWatermark(coordinator, store)
        coordinator.failNextHistoryScan = HistoryScanFailure.fetchFailed("nope")
        await coordinator.mergeChanges(into: store)

        #expect(
            failures.value.isEmpty,
            "a store that can't answer from history still works — that is a capability gap, not a fault"
        )
    }

    @Test("more than one store behind the container always re-reads everything")
    func multipleStoresReReadEverything() async throws {
        let schema = Schema([NoteModel.self])
        let directory = URL.temporaryDirectory.appending(path: "swidux-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration("a", schema: schema, url: directory.appending(path: "a.store")),
                ModelConfiguration("b", schema: schema, url: directory.appending(path: "b.store")),
            ])
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = try makeNotesCoordinator(
            container: container, debounce: .seconds(30), onDiagnostic: onDiagnostic)
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "mine", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)
        log.clear()

        try await remoteWrite(coordinator, writes: [Note(id: id, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id]?.title == "edited elsewhere")
        #expect(log.contains(.historyUnavailable))
        #expect(!log.contains(.remoteChangesMerged))
    }

    // MARK: - Withholding carries forward instead of pinning the anchor

    @Test("a fallback that withheld a row still anchors, so the next tick can narrow")
    func aWithholdingFallbackStillAnchors() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30), onDiagnostic: onDiagnostic)
        let held = UUID()
        let store = makeNotesStore(coordinator)

        // Memory and storage agree, and nothing is pending — so the hold below is
        // the *only* thing that can withhold anything. No watermark is
        // established first, deliberately: the tick that withholds has to be the
        // full-read fallback, which is the path that used to leave no anchor.
        store.send(.add(Note(id: held, title: "being edited", pinned: false)))
        await coordinator.corePlugin.flush()
        try await withholdARemoteEdit(coordinator, store, held)

        #expect(store.notes[held]?.title == "being edited", "a hold defers a remote change")
        #expect(log.fallbackReasons.contains("no watermark yet"))
        #expect(
            coordinator.handle.anchor.token != nil,
            "a withheld row is carried forward, so the window it came from is still safe to anchor"
        )
        log.clear()

        // The hold is still in force, so this tick withholds again. It must not
        // cost another full-table read to do it.
        await coordinator.mergeChanges(into: store)

        #expect(
            !log.contains(.historyUnavailable),
            "an unreleased hold used to leave the session unanchored, making every tick O(N)")
        #expect(log.contains(.remoteChangesMerged), "the carried-over row is re-offered by the narrow path")
        #expect(store.notes[held]?.title == "being edited")
    }

    @Test("a hold lifting delivers through the narrow path, though nothing new was written")
    func aCarriedOverRowNeedsNoNewTransaction() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let (coordinator, store, held) = try await makeAnchoredNote(
            title: "being edited", onDiagnostic: onDiagnostic)

        try await withholdARemoteEdit(coordinator, store, held)
        #expect(store.notes[held]?.title == "being edited")
        log.clear()

        // Nothing is written between here and the next tick. Releasing a hold
        // records no transaction, so the window this tick scans is empty and the
        // carry-over is the only thing that still names the row.
        coordinator.editing.release(held)
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[held]?.title == "edited elsewhere")
        #expect(!log.contains(.historyUnavailable), "an empty window is no reason to re-read the table")
        #expect(log.contains(.remoteChangesMerged))
    }

    @Test("a carried-over deletion is refused once the row is back on disk")
    func aCarriedOverDeletionIsRefutedByALiveRow() async throws {
        let (coordinator, store, id) = try await makeAnchoredNote(title: "being edited")

        coordinator.editing.hold(id)
        try await remoteWrite(coordinator, deletions: [id])
        await coordinator.mergeChanges(into: store)
        #expect(store.notes[id] != nil, "a hold defers a remote deletion")

        // Re-created elsewhere while the hold was in force. The deletion is
        // still owed, but the row it named is back — and a row storage holds
        // outranks a tombstone, carried over or not.
        try await remoteWrite(coordinator, writes: [Note(id: id, title: "back again", pinned: false)])
        coordinator.editing.release(id)
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id]?.title == "back again")
    }

    @Test("swapping the database discards what was carried over, not just the token")
    func swappingTheDatabaseDiscardsTheCarryOver() async throws {
        let (coordinator, store, held) = try await makeAnchoredNote(title: "being edited")

        try await withholdARemoteEdit(coordinator, store, held)
        #expect(!coordinator.handle.anchor.carryOver.isEmpty, "there has to be a debt to discard")

        coordinator.handle.db = EntityDB(modelContainer: try makeNotesContainer())

        #expect(
            coordinator.handle.anchor.carryOver.isEmpty,
            "identities resolved against one store say nothing about another, exactly as its token doesn't"
        )
    }

    @Test("a deletion withheld by an editing hold is applied once the hold lifts")
    func withheldDeletionIsReOfferedAfterTheHoldLifts() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let held = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: held, title: "being edited", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

        coordinator.editing.hold(held)
        try await remoteWrite(coordinator, deletions: [held])

        await coordinator.mergeChanges(into: store)
        #expect(store.notes[held] != nil, "a hold defers a remote change")

        // The hold lifts, and *no new transaction is written*. Under a watermark
        // that advanced on the withheld tick, nothing would ever mention this row
        // again and the deletion would be lost for good.
        coordinator.editing.release(held)
        await coordinator.mergeChanges(into: store)

        #expect(
            store.notes[held] == nil,
            "the same window has to be re-offered, or a hold silently becomes a veto")
    }

    @Test("an edit withheld by an editing hold is applied once the hold lifts")
    func withheldEditIsReOfferedAfterTheHoldLifts() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let held = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: held, title: "being edited", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

        coordinator.editing.hold(held)
        try await remoteWrite(coordinator, writes: [Note(id: held, title: "edited elsewhere", pinned: true)])

        await coordinator.mergeChanges(into: store)
        #expect(store.notes[held]?.title == "being edited")

        coordinator.editing.release(held)
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[held]?.title == "edited elsewhere")
    }

    @Test("swapping the database discards the watermark, and refuses to take it back")
    func swappingTheDatabaseDiscardsTheWatermark() async throws {
        // A store with no transactions has no token to anchor to, so there has
        // to be at least one write before there is a watermark to discard.
        let (coordinator, _, _) = try await makeAnchoredNote(title: "anything")
        let stale = coordinator.handle.anchor
        let token = try #require(stale.token)

        coordinator.handle.db = EntityDB(modelContainer: try makeNotesContainer())

        #expect(
            coordinator.handle.anchor.token == nil,
            "a token means nothing to a store that didn't issue it, and a stale one reads as 'nothing changed'"
        )
        // A tick suspended across the swap, arriving with the old store's answer.
        let reinstalled = coordinator.handle.installAnchor(
            watermark: token, carryOver: nil, ifGeneration: stale.generation)
        #expect(reinstalled == false)
        #expect(coordinator.handle.anchor.token == nil)
    }

    @Test("an older token does not rewind the watermark")
    func olderTokenDoesNotRewind() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: UUID(), title: "one", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)
        let first = try #require(coordinator.handle.anchor.token)

        store.send(.add(Note(id: UUID(), title: "two", pinned: false)))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)
        let second = try #require(coordinator.handle.anchor.token)
        #expect(second > first, "the second tick consumed a later window")

        // The slower of two overlapping ticks, arriving late with its older answer.
        let generation = coordinator.handle.anchor.generation
        #expect(coordinator.handle.installAnchor(watermark: first, carryOver: nil, ifGeneration: generation) == false)
        #expect(coordinator.handle.anchor.token == second)
    }

    // MARK: - Pruning

    @Test("hydration prunes transactions older than the retention window")
    func hydrationPrunesOldHistory() async throws {
        let container = try makeNotesContainer()
        let (log, onDiagnostic) = diagnosticLog()
        // A negative window puts the cutoff in the future, so everything already
        // recorded counts as expired. Transactions can't be backdated, and this
        // is the automatic path — the point is that nobody had to call anything.
        let coordinator = try makeNotesCoordinator(
            container: container, debounce: .seconds(30), historyRetention: .seconds(-60),
            onDiagnostic: onDiagnostic)
        let store = makeNotesStore(coordinator)

        try seedNotes(container, [Note(id: UUID(), title: "old news", pinned: false)])
        #expect(
            try await coordinator.database.historyTransactionCount() > 0,
            "there must be something to prune, or the test proves nothing")

        await coordinator.hydrate(into: store)
        // Pruning is detached so it can't sit on the launch path, so this waits
        // for it rather than assuming it already ran.
        try await poll(until: { log.contains(.historyPruned) })

        #expect(try await coordinator.database.historyTransactionCount() == 0)
        #expect(log.contains(.historyPruned))
    }

    @Test("history is pruned once per session, not on every hydration")
    func pruningRunsOncePerSession() async throws {
        let container = try makeNotesContainer()
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = try makeNotesCoordinator(
            container: container, debounce: .seconds(30), historyRetention: .seconds(-60),
            onDiagnostic: onDiagnostic)
        let store = makeNotesStore(coordinator)

        try seedNotes(container, [Note(id: UUID(), title: "old news", pinned: false)])
        await coordinator.hydrate(into: store)
        try await poll(until: { log.contains(.historyPruned) })
        log.clear()

        try seedNotes(container, [Note(id: UUID(), title: "newer", pinned: false)])
        await coordinator.hydrate(into: store)
        // A negative assertion, so it has to wait rather than poll: give the
        // detached prune every chance to fire before concluding it didn't.
        try await Task.sleep(for: .milliseconds(120))

        #expect(!log.contains(.historyPruned))
        #expect(try await coordinator.database.historyTransactionCount() > 0)
    }

    @Test("pruning keeps transactions newer than the cutoff")
    func pruningKeepsRecentHistory() async throws {
        let container = try makeNotesContainer()
        let coordinator = try makeNotesCoordinator(container: container, debounce: .seconds(30))

        try seedNotes(container, [Note(id: UUID(), title: "recent", pinned: false)])
        let before = try await coordinator.database.historyTransactionCount()

        let removed = await coordinator.pruneHistory(before: Date(timeIntervalSinceNow: -60))

        #expect(removed == 0)
        #expect(try await coordinator.database.historyTransactionCount() == before)
    }

    @Test("a tick never prunes on its own")
    func aTickNeverPrunes() async throws {
        let container = try makeNotesContainer()
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = try makeNotesCoordinator(
            container: container, debounce: .seconds(30), onDiagnostic: onDiagnostic)
        let store = makeNotesStore(coordinator)

        try seedNotes(container, [Note(id: UUID(), title: "recent", pinned: false)])
        await establishWatermark(coordinator, store)
        let before = try await coordinator.database.historyTransactionCount()

        try await remoteWrite(coordinator, writes: [Note(id: UUID(), title: "newer", pinned: false)])
        await coordinator.mergeChanges(into: store)

        #expect(try await coordinator.database.historyTransactionCount() >= before)
        #expect(!log.contains(.historyPruned), "pruning belongs to launch, not to the tick")
    }

    @Test("opting out of retention leaves history alone")
    func retentionCanBeDisabled() async throws {
        let container = try makeNotesContainer()
        let coordinator = try makeNotesCoordinator(
            container: container, debounce: .seconds(30), historyRetention: nil)
        let store = makeNotesStore(coordinator)

        try seedNotes(container, [Note(id: UUID(), title: "kept forever", pinned: false)])
        await coordinator.hydrate(into: store)

        #expect(try await coordinator.database.historyTransactionCount() > 0)
    }

    @Test("a local store is not mistaken for a CloudKit-mirrored one")
    func localStoresArePrunable() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        #expect(
            await coordinator.database.isCloudKitBacked == false,
            "a false positive here would silently disable pruning for every local app")
    }
}

extension EntityDB {
    /// How many transactions retained history currently holds.
    fileprivate func historyTransactionCount() throws -> Int {
        try transactions(since: nil).count
    }
}
