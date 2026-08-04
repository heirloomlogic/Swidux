//
//  PersistenceRetryTests.swift
//  SwiduxPersistenceTests
//
//  End-to-end cover for #58: a save that fails is retried rather than dropped,
//  and giving up is an event the app can see.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

/// A container that accepts writes into its context and refuses to save them.
///
/// The only reliable way to make `EntityDB` throw from a test: corrupting the
/// store file is served from cache, and a type absent from the schema fetches
/// empty rather than erroring. `allowsSave: false` stands in for a full disk or
/// a model the container can't encode.
///
/// It has to be a real file. A read-only *in-memory* store resolves to
/// `/dev/null` and fails to load at all, so the store is created writable,
/// seeded, released, and then reopened read-only.
@MainActor
func makeUnwritableNotesContainer(seeding seed: [Note] = []) throws -> ModelContainer {
    let schema = Schema([NoteModel.self])
    let url = URL.temporaryDirectory.appending(path: "swidux-readonly-\(UUID().uuidString).store")

    do {
        let writable = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = ModelContext(writable)
        for note in seed { context.insert(NoteModel(from: note)) }
        try context.save()
    }

    return try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false)]
    )
}

@Suite("Persistence retry")
@MainActor
struct PersistenceRetryTests {
    private typealias FailureLog = SendableBox<[PersistenceFailure]>

    private func makeFailingCoordinator(
        retry: RetryPolicy,
        log: FailureLog,
        seeding seed: [Note] = []
    ) throws -> PersistenceCoordinator<NotesState, NotesAction> {
        PersistenceCoordinator<NotesState, NotesAction>(
            entities: [.entity(\.notes)],
            container: try makeUnwritableNotesContainer(seeding: seed),
            debounce: .milliseconds(10),
            retry: retry,
            onFailure: { failure in log.withValue { $0.append(failure) } }
        )
    }

    // Two attempts, not more, deliberately. A third save against a store that
    // can *never* be written trips a fatal error inside `ModelContext`
    // ("This store went missing?") — reproducible with two bare `EntityDB.apply`
    // calls and none of this machinery, so it is SwiftData's handling of a
    // read-only store rather than anything retrying does. Deeper retry
    // sequences are covered against a fake persist closure in
    // `PersistencePluginTests`, where no store is involved.
    @Test("A failing save is retried, then reported once as final")
    func exhaustedSaveIsReportedAsFinal() async throws {
        let log = FailureLog([])
        let coordinator = try makeFailingCoordinator(
            retry: RetryPolicy(
                maxAttempts: 2, baseDelay: .milliseconds(10), maxDelay: .milliseconds(20)),
            log: log
        )

        var state = NotesState()
        let note = Note(id: UUID(), title: "never lands", pinned: false)
        state.notes[note.id] = note
        coordinator.corePlugin.drainAndScheduleFlush(&state)

        try await poll(until: { log.value.contains(where: \.isFinal) }, timeout: .seconds(5))

        let saves = log.value.filter { $0.operation == .save }
        #expect(saves.count == 3, "two attempts, each reported, plus one terminal report")
        #expect(saves.filter(\.isFinal).count == 1, "giving up is reported exactly once")
        #expect(saves.last?.isFinal == true)
        #expect(saves.allSatisfy { $0.entityType == "Note" })
        #expect(saves.allSatisfy { ($0.underlying as NSError).code == 513 })
    }

    @Test("A write whose save never lands is never overwritten by the stored row")
    func exhaustedWriteSurvivesRehydrate() async throws {
        let log = FailureLog([])
        // A stale row on disk, so the merge has something to overwrite memory
        // with if the failed write is not treated as locally owned.
        let id = UUID()
        let coordinator = try makeFailingCoordinator(
            retry: .never,
            log: log,
            seeding: [Note(id: id, title: "stale disk row", pinned: false)]
        )

        let store = makeNotesStore(coordinator)
        let edited = Note(id: id, title: "local edit", pinned: true)
        store.send(.add(edited))

        // The dispatch drains into the writer; the flush then fails, so the
        // edit exists only in memory.
        await coordinator.corePlugin.flush()
        try await poll(until: { !log.value.isEmpty }, timeout: .seconds(5))
        #expect(!log.value.isEmpty, "the premise of this test is that the save failed")

        await coordinator.rehydrate(into: store)

        #expect(
            store.notes[id] == edited,
            "an ID whose write never reached storage stays locally owned"
        )
    }

    @Test("A transient failure is retried and the write lands on the retry")
    func transientFailureLandsOnRetry() async throws {
        // The coordinator's own write path can't be made to fail selectively,
        // so the recovery half is driven through StateWriter directly — the
        // same closure PersistedEntity installs, minus SwiftData.
        let attempts = SendableBox(0)
        let stored = SendableBox<[Note]>([])

        let writer = StateWriter<NotesState>(keyPath: \.notes) { writes, _ in
            let attempt = attempts.withValue { count -> Int in
                count += 1
                return count
            }
            if attempt == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            stored.value = writes
        }
        let plugin = PersistencePlugin<NotesState, NotesAction>(
            writers: [writer],
            debounce: .milliseconds(10),
            retry: RetryPolicy(
                maxAttempts: 3, baseDelay: .milliseconds(10), maxDelay: .milliseconds(40))
        )

        var state = NotesState()
        let note = Note(id: UUID(), title: "lands on retry", pinned: false)
        state.notes[note.id] = note
        plugin.afterReduce(state: &state, action: .add(note))

        try await poll(until: { !stored.value.isEmpty }, timeout: .seconds(5))
        #expect(stored.value == [note])
        #expect(writer.pendingIDs.isEmpty, "a successful retry clears the buffer")
    }
}
