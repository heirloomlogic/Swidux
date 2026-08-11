//
//  EntityScopedMergeTests.swift
//  SwiduxPersistenceTests
//
//  Cover for #79: a tick that narrows its work from persistent history knows
//  *which* entity each changed identity belongs to, and reads only those.
//
//  What is being asserted is mostly a negative — that an entity nothing changed
//  in was never touched — so every test here needs a way to observe a read that
//  should not have happened. Duplicate rows are that way: any read that touches
//  them collapses them and says so, which is the probe
//  `HistoryWatermarkTests.readsOnlyWhatChanged` established for the same
//  question one entity down.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Helpers

/// Runs the first tick, which has no watermark and so always re-reads
/// everything, leaving an anchor behind for the tick each test cares about.
@MainActor
private func establishWatermark(
    _ coordinator: PersistenceCoordinator<TaggedState, TaggedAction>,
    _ store: Store<TaggedState, TaggedAction>
) async {
    await coordinator.mergeChanges(into: store)
}

@Suite("PersistenceCoordinator.mergeChanges, scoped per entity")
@MainActor
struct EntityScopedMergeTests {
    @Test("an entity history says nothing changed in is not read")
    func unchangedEntityIsNotRead() async throws {
        let container = try makeTaggedContainer()
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = try makeTaggedCoordinator(container: container, onDiagnostic: onDiagnostic)
        let store = makeTaggedStore(coordinator)

        // One identity, deliberately shared by a note and a pair of duplicate
        // tag rows. Identities don't collide across types in practice; making
        // them collide here is what turns "was the tag entity read?" into
        // something a test can see, because under a flat ID set the tag entity
        // is handed this ID and finds rows for it.
        let shared = UUID()
        try seedTags(
            container,
            [Tag(id: shared, label: "twin"), Tag(id: shared, label: "twin")])

        await establishWatermark(coordinator, store)
        #expect(
            log.contains(.duplicateRowsCollapsed, entityType: "Tag"),
            "the anchoring full read must have seen the duplicates, or the probe proves nothing")
        log.clear()

        try await remoteWriteNotes(
            coordinator, writes: [Note(id: shared, title: "from a peer", pinned: false)])
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[shared]?.title == "from a peer")
        #expect(
            !log.contains(.duplicateRowsCollapsed, entityType: "Tag"),
            "history named the ID as a note, so the tag entity had nothing to read")
        #expect(log.contains(.remoteChangesMerged))
    }

    @Test("a row carried over from one entity does not read another")
    func carryOverIsScopedToItsOwnEntity() async throws {
        let container = try makeTaggedContainer()
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = try makeTaggedCoordinator(container: container, onDiagnostic: onDiagnostic)
        let store = makeTaggedStore(coordinator)

        // The same collision probe as above: one identity belonging to a note
        // and to a pair of duplicate tag rows, so a tag read that shouldn't have
        // happened announces itself.
        let shared = UUID()
        try seedTags(container, [Tag(id: shared, label: "twin"), Tag(id: shared, label: "twin")])
        store.send(.addNote(Note(id: shared, title: "being edited", pinned: false)))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)
        log.clear()

        // Withheld as a note, so the carry-over records it under the note
        // entity — the same key the scan would have grouped it under.
        coordinator.editing.hold(shared)
        try await remoteWriteNotes(
            coordinator, writes: [Note(id: shared, title: "from a peer", pinned: false)])
        await coordinator.mergeChanges(into: store)
        log.clear()

        // This tick's window is empty, so the carry-over is the only thing
        // naming any work at all.
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[shared]?.title == "being edited", "the hold is still in force")
        #expect(
            !log.contains(.duplicateRowsCollapsed, entityType: "Tag"),
            "a debt owed by the note entity must not put the tag entity back on the read path")
    }

    @Test("every entity history names is merged, and none is dropped")
    func bothEntitiesMerge() async throws {
        let coordinator = try makeTaggedCoordinator()
        let store = makeTaggedStore(coordinator)
        await establishWatermark(coordinator, store)

        let note = UUID()
        let tag = UUID()
        try await remoteWriteNotes(coordinator, writes: [Note(id: note, title: "note", pinned: false)])
        try await remoteWriteTags(coordinator, writes: [Tag(id: tag, label: "tag")])

        await coordinator.mergeChanges(into: store)

        #expect(store.notes[note]?.title == "note")
        #expect(store.tags[tag]?.label == "tag")
    }

    @Test("a deletion is attributed to its own entity, alongside another's edit")
    func deletionIsAttributed() async throws {
        let coordinator = try makeTaggedCoordinator()
        let store = makeTaggedStore(coordinator)
        let note = UUID()
        let doomed = UUID()
        store.send(.addNote(Note(id: note, title: "mine", pinned: false)))
        store.send(.addTag(Tag(id: doomed, label: "doomed")))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

        try await remoteWriteNotes(
            coordinator, writes: [Note(id: note, title: "edited elsewhere", pinned: true)])
        try await remoteWriteTags(coordinator, deletions: [doomed])

        await coordinator.mergeChanges(into: store)

        #expect(store.notes[note]?.title == "edited elsewhere")
        #expect(store.tags[doomed] == nil, "a tombstone is positive evidence of deletion")
    }

    @Test("an entity whose only change is a deletion is still read")
    func deletionAloneStillReadsItsEntity() async throws {
        let coordinator = try makeTaggedCoordinator()
        let store = makeTaggedStore(coordinator)
        let doomed = UUID()
        store.send(.addTag(Tag(id: doomed, label: "doomed")))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

        // Nothing changed in `notes` at all, so `tags` is the only entity with
        // anything to do — and its only entry is in the deleted map. Skipping an
        // entity whose changed set is empty would drop this deletion entirely.
        try await remoteWriteTags(coordinator, deletions: [doomed])
        await coordinator.mergeChanges(into: store)

        #expect(store.tags[doomed] == nil)
        #expect(
            store.tags.changes.isEmpty,
            "a deletion read from history must not be echoed back to storage as a local one")
    }

    @Test("a declared deletion is refused when the row is still on disk")
    func deletionIsRefutedByALiveRow() async throws {
        let coordinator = try makeTaggedCoordinator()
        let store = makeTaggedStore(coordinator)
        let revived = UUID()
        store.send(.addTag(Tag(id: revived, label: "first")))
        await coordinator.corePlugin.flush()
        await establishWatermark(coordinator, store)

        // Deleted and re-inserted elsewhere inside one window. The tombstone
        // names it, but the row is back — so the read that refutes the tombstone
        // has to be the one scoped to `tags`, not a spare pass by `notes`.
        try await remoteWriteTags(coordinator, deletions: [revived])
        try await remoteWriteTags(coordinator, writes: [Tag(id: revived, label: "back again")])

        await coordinator.mergeChanges(into: store)

        #expect(store.tags[revived]?.label == "back again")
    }
}
