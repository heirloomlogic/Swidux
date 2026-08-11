//
//  ReadFailureTests.swift
//  SwiduxPersistenceTests
//
//  Cover for #87: what every read path does when the fetch behind it throws.
//
//  Four `catch` blocks in `PersistedEntity` and the `allReadsSucceeded` guard in
//  `PersistenceCoordinator.merge` all exist to keep one confusion from happening —
//  a database that could not be read must never present as a database with
//  nothing in it. Until `EntityDB.failNextFetch(with:)` there was no way to reach
//  any of them: `allowsSave: false` fails saves and leaves reads working, an
//  in-memory store does not fail at all, and `failNextHistoryScan` covers the
//  scan rather than the read.
//
//  Like the `scanFailures` suite next door, these prove the **escalation** — that
//  a read which threw is reported and applies nothing — not that a real SwiftData
//  fetch throws rather than trapping. That trade was judged acceptable there and
//  is the same one here.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Helpers

/// Stands in for a store that cannot answer: a revoked file handle, a container
/// yanked mid-tick, a corrupt store. What it is matters less than that it throws
/// out of the fetch, which is the only thing every caller under test can see.
private let unreadable = CocoaError(.fileReadCorruptFile)

/// A coordinator and store holding one flushed note, already anchored.
///
/// The same starting point `HistoryWatermarkTests` builds, plus the failure
/// handler these tests need — a read failure is delivered there, not to
/// `onDiagnostic`.
@MainActor
private func makeAnchoredNote(
    title: String = "mine"
) async throws -> (
    coordinator: PersistenceCoordinator<NotesState, NotesAction>,
    store: Store<NotesState, NotesAction>, id: UUID,
    failures: SendableBox<[PersistenceFailure]>
) {
    let (failures, onFailure) = failureLog()
    let coordinator = try makeNotesCoordinator(debounce: .seconds(30), onFailure: onFailure)
    let id = UUID()
    let store = makeNotesStore(coordinator)
    store.send(.add(Note(id: id, title: title, pinned: false)))
    await coordinator.corePlugin.flush()
    // The first tick has no watermark, so it re-reads everything and leaves the
    // anchor the tests below actually care about.
    await coordinator.mergeChanges(into: store)
    return (coordinator, store, id, failures)
}

// MARK: - The seam itself

@Suite("EntityDB.failNextFetch")
struct FetchFailureSeamTests {
    @Test("the armed read throws and the one after it succeeds")
    @MainActor
    func theSeamFailsExactlyOneRead() async throws {
        let db = EntityDB(modelContainer: try makeNotesContainer())
        try await db.upsert(Note(id: UUID(), title: "A", pinned: false), as: NoteModel.self)

        await db.failNextFetch(with: unreadable)
        await #expect(throws: CocoaError.self) { try await db.fetchAll(NoteModel.self) }

        // One-shot, like `failNextHistoryScan`. Every test that asserts a window
        // is re-read on the *next* tick depends on this.
        let recovered = try await db.fetchAll(NoteModel.self)
        #expect(recovered.count == 1, "arming once must not poison every later read")
    }

    @Test("a by-ID read is armed by the same seam as a whole-table one")
    @MainActor
    func theSeamCoversTheByIDRead() async throws {
        let db = EntityDB(modelContainer: try makeNotesContainer())
        let id = UUID()
        try await db.upsert(Note(id: id, title: "A", pinned: false), as: NoteModel.self)

        await db.failNextFetch(with: unreadable)
        await #expect(throws: CocoaError.self) { try await db.fetch(ids: [id], of: Note.self) }

        #expect(try await db.fetch(ids: [id], of: Note.self).count == 1)
    }

    @Test("arming a read does not fail the write path")
    @MainActor
    func theSeamLeavesWritesAlone() async throws {
        // `apply` fetches the rows it is about to touch, through the same
        // chunked by-ID query a read uses. Seaming that shared helper rather
        // than the two read entry points would make "the read failed" and "the
        // save failed" the same event.
        let db = EntityDB(modelContainer: try makeNotesContainer())
        let id = UUID()

        await db.failNextFetch(with: unreadable)
        try await db.upsert(Note(id: id, title: "written anyway", pinned: false), as: NoteModel.self)

        await #expect(throws: CocoaError.self) { try await db.fetchAll(NoteModel.self) }
        #expect(try await db.fetchAll(NoteModel.self).first?.title == "written anyway")
    }
}

// MARK: - Hydration

@Suite("Reads that throw")
@MainActor
struct ReadFailureTests {
    @Test("first-load hydration leaves the store untouched rather than empty")
    func hydrationLeavesTheStoreUntouched() async throws {
        let (failures, onFailure) = failureLog()
        let container = try makeNotesContainer()
        let onDisk = Note(id: UUID(), title: "on disk", pinned: false)
        try seedNotes(container, [onDisk])
        let coordinator = try makeNotesCoordinator(
            container: container, debounce: .seconds(30), onFailure: onFailure)

        // Something already in memory, so "left untouched" and "emptied" are
        // distinguishable outcomes. This is the data-loss guard: a store that
        // hydrates to empty would have a later flush write that empty world view
        // over whatever was still recoverable on disk.
        var state = NotesState()
        let local = Note(id: UUID(), title: "already in memory", pinned: false)
        state.notes[local.id] = local

        await coordinator.database.failNextFetch(with: unreadable)
        await coordinator.hydrate(into: &state)

        #expect(state.notes[local.id] == local, "an unreadable database must not present as no data")
        #expect(state.notes[onDisk.id] == nil, "the disk row was never read")
        #expect(state.notes.count == 1)
        #expect(failures.failures(.fetch).count == 1, "a fetch that failed is reported, not swallowed")
        #expect(failures.failures(.fetch).first?.entityType == "Note")
        #expect((failures.failures(.fetch).first?.underlying as? CocoaError) == unreadable)
        #expect(failures.failures(.fetch).first?.isFinal == false, "a fetch is not retried")
    }

    @Test("re-hydration leaves live state untouched rather than empty")
    func rehydrationLeavesLiveStateUntouched() async throws {
        let (coordinator, store, id, failures) = try await makeAnchoredNote()

        // A peer's edit that the whole-table read would otherwise surface, so
        // "applied nothing" is an observable outcome rather than a coincidence.
        try await remoteWrite(coordinator, writes: [Note(id: id, title: "edited elsewhere", pinned: true)])

        await coordinator.database.failNextFetch(with: unreadable)
        await coordinator.rehydrate(into: store)

        #expect(store.notes[id]?.title == "mine", "a read that threw applies nothing")
        #expect(store.notes.count == 1, "and removes nothing either")
        #expect(failures.failures(.fetch).count == 1)
        #expect(failures.failures(.fetch).first?.entityType == "Note")
    }

    // MARK: - The watermark guard

    @Test("a read that threw does not advance the watermark past the window it missed")
    func aFailedReadDoesNotConsumeTheWindow() async throws {
        let (coordinator, store, id, failures) = try await makeAnchoredNote()
        let before = coordinator.handle.anchor.token
        #expect(before != nil, "the premise: there is an anchor to hold still")

        try await remoteWrite(coordinator, writes: [Note(id: id, title: "edited elsewhere", pinned: true)])

        await coordinator.database.failNextFetch(with: unreadable)
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id]?.title == "mine", "a read that threw applies nothing")
        #expect(
            coordinator.handle.anchor.token == before,
            """
            a watermark consumes its evidence once, so advancing past a window that was \
            never read loses the change in it for good
            """)
        #expect(failures.failures(.fetch).count == 1)

        // The seam is spent, so this tick reads for real — and it can only see
        // the peer's edit because the window above was left unconsumed.
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[id]?.title == "edited elsewhere", "the window was re-offered, not lost")
        #expect(coordinator.handle.anchor.token != before, "a tick that read everything moves on")
    }

    @Test("one entity's failed read pins the window even though the other was read")
    func oneFailedReadOfTwoPinsTheWindow() async throws {
        let coordinator = try makeTaggedCoordinator()
        let store = makeTaggedStore(coordinator)
        await coordinator.mergeChanges(into: store)
        let before = coordinator.handle.anchor.token

        let note = UUID()
        let tag = UUID()
        try await remoteWriteNotes(coordinator, writes: [Note(id: note, title: "from a peer", pinned: false)])
        try await remoteWriteTags(coordinator, writes: [Tag(id: tag, label: "also from a peer")])

        // `notes` is registered first, so the one-shot seam takes its read and
        // leaves `tags`' intact. That asymmetry is the whole point: a phase that
        // read *most* of its entities is still a phase that cannot account for
        // the window.
        await coordinator.database.failNextFetch(with: unreadable)
        await coordinator.mergeChanges(into: store)

        #expect(store.notes[note] == nil, "the entity whose read threw applied nothing")
        #expect(store.tags[tag]?.label == "also from a peer", "the entity that was read still applied")
        #expect(
            coordinator.handle.anchor.token == before,
            "one unread entity is enough to hold the whole window open")

        await coordinator.mergeChanges(into: store)

        #expect(store.notes[note]?.title == "from a peer", "the re-offer delivers what the failed read missed")
        #expect(coordinator.handle.anchor.token != before)
    }

    // MARK: - The caller-fed path

    @Test("a caller-fed merge whose read threw leaves the existing debt standing")
    func aFailedReadKeepsTheDebtItCannotRecompute() async throws {
        let coordinator = try makeNotesCoordinator(debounce: .seconds(30))
        let store = makeNotesStore(coordinator)
        let held = UUID()
        store.send(.add(Note(id: held, title: "being edited", pinned: false)))
        await coordinator.corePlugin.flush()

        // A hold defers the peer's edit, which is what records the debt. Without
        // one there is nothing for the failed tick to lose.
        coordinator.editing.hold(held)
        try await remoteWrite(coordinator, writes: [Note(id: held, title: "edited elsewhere", pinned: true)])
        await coordinator.mergeRemote(into: store, ids: [held])
        let owed = coordinator.handle.anchor.carryOver.reading(for: "NoteModel")
        #expect(!owed.isEmpty, "the premise: there is a debt to lose")

        await coordinator.database.failNextFetch(with: unreadable)
        await coordinator.mergeRemote(into: store, ids: [held])

        #expect(
            coordinator.handle.anchor.carryOver.reading(for: "NoteModel") == owed,
            """
            the debt is replaced rather than accumulated, so a tick that read nothing \
            must not report an empty one — that would drop the row for good
            """)

        // Releasing the hold and reading for real settles it, which is only
        // possible because the identity survived the failed tick.
        coordinator.editing.release(held)
        await coordinator.mergeRemote(into: store, ids: [])

        #expect(store.notes[held]?.title == "edited elsewhere", "the carried-over row is still delivered")
        #expect(coordinator.handle.anchor.carryOver.reading(for: "NoteModel").isEmpty)
    }

    @Test("a partial read that threw is not mistaken for a row that vanished")
    func aFailedPartialReadRemovesNothing() async throws {
        let (coordinator, store, id, failures) = try await makeAnchoredNote()

        // A tombstone the caller declares, against a read that never happens.
        // An empty result from a by-ID read is already not evidence of deletion;
        // a read that *threw* must be even less so.
        await coordinator.database.failNextFetch(with: unreadable)
        await coordinator.mergeRemote(into: store, ids: [id], deleted: [id])

        #expect(store.notes[id]?.title == "mine", "a read that threw cannot authorise a removal")
        #expect(failures.failures(.fetch).count == 1)
    }
}
