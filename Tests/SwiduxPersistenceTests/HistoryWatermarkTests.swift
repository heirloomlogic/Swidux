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

/// Collects diagnostics off the `@Sendable` handler.
private func diagnosticLog() -> (SendableBox<[PersistenceDiagnostic]>, PersistenceDiagnosticHandler) {
    let box = SendableBox<[PersistenceDiagnostic]>([])
    return (box, { diagnostic in box.withValue { $0.append(diagnostic) } })
}

extension SendableBox where T == [PersistenceDiagnostic] {
    fileprivate var kinds: [PersistenceDiagnostic.Kind] { value.map(\.kind) }

    fileprivate func contains(_ kind: PersistenceDiagnostic.Kind) -> Bool {
        kinds.contains(kind)
    }

    fileprivate var fallbackReasons: [String] {
        value.filter { $0.kind == .historyUnavailable }.compactMap(\.fallbackReason)
    }

    fileprivate func clear() { value = [] }
}

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

/// Writes `notes` the way another device's changes arrive — through the
/// database, behind the store's back.
@MainActor
private func remoteWrite(
    _ coordinator: PersistenceCoordinator<NotesState, NotesAction>,
    writes: [Note] = [],
    deletions: Set<UUID> = []
) async throws {
    try await coordinator.database.apply(
        writes: writes, deletions: deletions, as: NoteModel.self)
}

// MARK: - The narrow path

@Suite("PersistenceCoordinator.mergeChanges")
@MainActor
struct HistoryWatermarkTests {
    @Test("a remote edit recorded in history surfaces")
    func surfacesARemoteEdit() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "mine", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

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
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let doomed = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: doomed, title: "doomed", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

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
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let only = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: only, title: "the only one", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

        try await remoteWrite(coordinator, deletions: [only])
        await coordinator.mergeChanges(into: store)

        // The empty-snapshot guard blocks this on the full path, deliberately.
        // Tombstones are evidence an empty table isn't, so the narrow path can.
        #expect(store.notes.isEmpty)
    }

    @Test("a window with no transactions does nothing at all")
    func emptyWindowIsANoOp() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30), onDiagnostic: onDiagnostic)
        let kept = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: kept, title: "kept", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)
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
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "mine", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

        try await remoteWrite(coordinator, writes: [Note(id: id, title: "edited elsewhere", pinned: true)])
        // Dispatched but never flushed: local intent the merge must not clobber.
        store.send(.add(Note(id: id, title: "typed just now", pinned: false)))

        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id]?.title == "typed just now")
    }

    @Test("a write drained during the fetch is not overwritten by the stored row")
    func writeDrainedDuringTheFetchSurvives() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "mine", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

        try await remoteWrite(coordinator, writes: [Note(id: id, title: "edited elsewhere", pinned: true)])
        // Lands after the flush and after the fetch was issued — the window the
        // late-bound dirty read exists to cover.
        coordinator.duringReadPhase = { store.send(.add(Note(id: id, title: "typed mid-fetch", pinned: false))) }

        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id]?.title == "typed mid-fetch")
    }

    @Test("a locally deleted row is not resurrected by its own history")
    func doesNotResurrectALocalDelete() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "doomed", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

        store.send(.remove(id))
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id] == nil)
    }

    @Test("a local delete undone before the tick refutes its own tombstone")
    func anUndoneDeleteOutranksItsOwnTombstone() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "kept after all", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

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

    @Test("an expired token re-reads everything")
    func expiredTokenReReadsEverything() async throws {
        try await expectFallback(injecting: SwiftDataError.historyTokenExpired)
    }

    @Test("any history-fetch failure re-reads everything")
    func anyScanFailureReReadsEverything() async throws {
        try await expectFallback(injecting: HistoryScanFailure.fetchFailed("the store said no"))
    }

    @Test("a deletion whose tombstone carries no identity re-reads everything")
    func unidentifiedDeletionReReadsEverything() async throws {
        try await expectFallback(injecting: HistoryScanFailure.unidentifiedDeletion(entityName: "NoteModel"))
    }

    /// Drives one fallback trigger end to end: the tick must still apply the
    /// remote change, and must say why it had to re-read to find it.
    private func expectFallback(injecting error: any Error) async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30), onDiagnostic: onDiagnostic)
        let id = UUID()
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: id, title: "mine", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)
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

    // MARK: - The watermark only advances on a clean tick

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

    @Test("swapping the database discards the watermark")
    func swappingTheDatabaseDiscardsTheWatermark() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let store = makeNotesStore(coordinator)
        // A store with no transactions has no token to anchor to, so there has
        // to be at least one write before there is a watermark to discard.
        store.send(.add(Note(id: UUID(), title: "anything", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)
        #expect(coordinator.handle.watermark.token != nil)

        coordinator.handle.db = EntityDB(modelContainer: try makeNotesContainer())

        #expect(
            coordinator.handle.watermark.token == nil,
            "a token means nothing to a store that didn't issue it, and a stale one reads as 'nothing changed'"
        )
    }

    @Test("a watermark computed against a swapped-away database is refused")
    func staleGenerationIsRefused() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let store = makeNotesStore(coordinator)
        store.send(.add(Note(id: UUID(), title: "anything", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

        let stale = coordinator.handle.watermark
        let token = try #require(stale.token)
        coordinator.handle.db = EntityDB(modelContainer: try makeNotesContainer())

        #expect(coordinator.handle.installWatermark(token, ifGeneration: stale.generation) == false)
        #expect(coordinator.handle.watermark.token == nil)
    }

    @Test("an older token does not rewind the watermark")
    func olderTokenDoesNotRewind() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let store = makeNotesStore(coordinator)

        store.send(.add(Note(id: UUID(), title: "one", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)
        let first = try #require(coordinator.handle.watermark.token)

        store.send(.add(Note(id: UUID(), title: "two", pinned: false)))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)
        let second = try #require(coordinator.handle.watermark.token)
        #expect(second > first, "the second tick consumed a later window")

        // The slower of two overlapping ticks, arriving late with its older answer.
        let generation = coordinator.handle.watermark.generation
        #expect(coordinator.handle.installWatermark(first, ifGeneration: generation) == false)
        #expect(coordinator.handle.watermark.token == second)
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
        log.clear()

        try seedNotes(container, [Note(id: UUID(), title: "newer", pinned: false)])
        await coordinator.hydrate(into: store)

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
        try modelContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).count
    }
}
