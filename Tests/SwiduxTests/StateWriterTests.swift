//
//  StateWriterTests.swift
//  SwiduxTests
//

import Foundation
import Testing

@testable import Swidux

/// Thread-safe box for collecting values from @Sendable closures.
final class SendableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    var value: T {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    init(_ value: T) { storage = value }

    /// Mutates in place under the lock — for read-modify-write, where a
    /// get/set pair would race.
    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&storage) }
    }
}

@Suite("StateWriter")
@MainActor
struct StateWriterTests {
    // MARK: - Helpers

    /// Creates a StateWriter for `TestState.items` that records persisted values.
    private static func makeWriter(
        persisted:
            @escaping @Sendable (_ writes: [TestEntity], _ deletions: Set<UUID>) async -> Void
    ) -> StateWriter<TestState> {
        StateWriter(keyPath: \.items, persist: persisted)
    }

    // MARK: - Drain

    @Test("Drain returns false when no changes exist")
    func drainNoChanges() {
        let writer = Self.makeWriter { _, _ in }
        var state = TestState()

        let hadChanges = writer.drain(&state)
        #expect(!hadChanges)
    }

    @Test("Drain returns true and resets changes when upserts exist")
    func drainWithUpserts() {
        let writer = Self.makeWriter { _, _ in }
        var state = TestState()
        let entity = TestEntity(name: "Inserted")
        state.items[entity.id] = entity

        #expect(!state.items.changes.isEmpty)

        let hadChanges = writer.drain(&state)
        #expect(hadChanges)
        // Changes should be reset on the EntityStore
        #expect(state.items.changes.isEmpty)
    }

    @Test("Drain captures deletions")
    func drainWithDeletions() async {
        let box = SendableBox<Set<UUID>>([])

        let writer = Self.makeWriter { _, deletions in
            box.value = deletions
        }

        var state = TestState()
        let entity = TestEntity(name: "ToDelete")
        state.items = EntityStore([entity])
        state.items[entity.id] = nil

        _ = writer.drain(&state)

        // Flush and execute to verify deletions were captured
        if let work = writer.flush() {
            _ = await work()
        }
        #expect(box.value.contains(entity.id))
    }

    @Test("Drain coalesces delete-after-insert — delete wins")
    func drainDeleteAfterInsert() async {
        let writesBox = SendableBox<[TestEntity]>([])
        let deletionsBox = SendableBox<Set<UUID>>([])

        let writer = Self.makeWriter { writes, deletions in
            writesBox.value = writes
            deletionsBox.value = deletions
        }

        var state = TestState()
        let entity = TestEntity(name: "Ephemeral")
        state.items[entity.id] = entity
        state.items[entity.id] = nil

        _ = writer.drain(&state)
        if let work = writer.flush() {
            _ = await work()
        }

        #expect(writesBox.value.isEmpty)
        #expect(deletionsBox.value.contains(entity.id))
    }

    @Test("Drain coalesces insert-after-delete across drains — insert wins")
    func drainInsertAfterDeleteAcrossDrains() async {
        let writesBox = SendableBox<[TestEntity]>([])
        let deletionsBox = SendableBox<Set<UUID>>([])

        let writer = Self.makeWriter { writes, deletions in
            writesBox.value = writes
            deletionsBox.value = deletions
        }

        var state = TestState()
        let entity = TestEntity(name: "Restored")
        state.items = EntityStore([entity])

        // Drain 1: delete. Drain 2: reinsert (the shape of undo-of-delete).
        state.items[entity.id] = nil
        _ = writer.drain(&state)
        state.items[entity.id] = entity
        _ = writer.drain(&state)

        if let work = writer.flush() {
            _ = await work()
        }

        // The reinsert must cancel the buffered deletion — otherwise the flush
        // delivers both and the delete wins at the database.
        #expect(writesBox.value == [entity])
        #expect(deletionsBox.value.isEmpty)
    }

    // MARK: - Flush

    @Test("Flush returns nil when nothing is pending")
    func flushEmpty() {
        let writer = Self.makeWriter { _, _ in }
        #expect(writer.flush() == nil)
    }

    @Test("Flush returns closure with correct writes and deletions")
    func flushPopulated() async {
        let writesBox = SendableBox<[TestEntity]>([])

        let writer = Self.makeWriter { writes, _ in
            writesBox.value = writes
        }

        let entity = TestEntity(name: "Persisted")
        var state = TestState()
        state.items[entity.id] = entity
        _ = writer.drain(&state)

        let work = writer.flush()
        #expect(work != nil)
        _ = await work!()

        #expect(writesBox.value.count == 1)
        #expect(writesBox.value.first?.name == "Persisted")
    }

    @Test("Flush clears pending buffers — double flush returns nil")
    func doubleFlush() {
        let writer = Self.makeWriter { _, _ in }
        let entity = TestEntity()
        var state = TestState()
        state.items[entity.id] = entity
        _ = writer.drain(&state)

        _ = writer.flush()  // first flush
        #expect(writer.flush() == nil)  // second flush should be nil
    }

    @Test("Multiple drains coalesce — last write wins")
    func multipleDrainsCoalesce() async {
        let writesBox = SendableBox<[TestEntity]>([])

        let writer = Self.makeWriter { writes, _ in
            writesBox.value = writes
        }

        let id = UUID()
        var state = TestState()

        // First mutation
        state.items[id] = TestEntity(id: id, name: "First")
        _ = writer.drain(&state)

        // Second mutation (same ID, different value)
        state.items[id] = TestEntity(id: id, name: "Second")
        _ = writer.drain(&state)

        if let work = writer.flush() {
            _ = await work()
        }

        #expect(writesBox.value.count == 1)
        #expect(writesBox.value.first?.name == "Second")
    }

    // MARK: - Failure re-buffering

    @Test("A failed flush restores its batch, so the next flush carries it again")
    func failedFlushRestoresBatch() async {
        let attempts = SendableBox(0)
        let seen = SendableBox<[TestEntity]>([])

        let writer = StateWriter<TestState>(keyPath: \.items) { writes, _ in
            attempts.value += 1
            if attempts.value == 1 { throw TestPersistError() }
            seen.value = writes
        }

        var state = TestState()
        let entity = TestEntity(name: "At risk")
        state.items[entity.id] = entity
        _ = writer.drain(&state)

        // Attempt 1 fails. Without re-buffering the batch is gone for good and
        // the row only ever reaches disk if the user touches it again.
        _ = await writer.flush()?()

        let retry = writer.flush()
        #expect(retry != nil, "the failed batch must still be pending")
        _ = await retry?()

        #expect(attempts.value == 2)
        #expect(seen.value == [entity])
    }

    @Test("A newer write drained during the failed flush beats the restored one")
    func newerWriteBeatsRestoredWrite() async {
        let seen = SendableBox<[TestEntity]>([])
        let attempts = SendableBox(0)

        let writer = StateWriter<TestState>(keyPath: \.items) { writes, _ in
            attempts.value += 1
            if attempts.value == 1 { throw TestPersistError() }
            seen.value = writes
        }

        let id = UUID()
        var state = TestState()
        state.items[id] = TestEntity(id: id, name: "First")
        _ = writer.drain(&state)

        // `flush()` snapshots and clears synchronously, so a drain between here
        // and the await is the real window: the user edited again while the
        // save was in flight.
        let work = writer.flush()
        state.items[id] = TestEntity(id: id, name: "Second")
        _ = writer.drain(&state)
        _ = await work?()

        _ = await writer.flush()?()

        #expect(seen.value.map(\.name) == ["Second"], "restoring must not resurrect a superseded value")
    }

    @Test("A deletion drained during the failed flush cancels the restored write")
    func deletionBeatsRestoredWrite() async {
        let writes = SendableBox<[TestEntity]>([])
        let deletions = SendableBox<Set<UUID>>([])
        let attempts = SendableBox(0)

        let writer = StateWriter<TestState>(keyPath: \.items) { w, d in
            attempts.value += 1
            if attempts.value == 1 { throw TestPersistError() }
            writes.value = w
            deletions.value = d
        }

        let id = UUID()
        var state = TestState()
        state.items = EntityStore([TestEntity(id: id, name: "Doomed")])
        state.items[id] = TestEntity(id: id, name: "Edited")
        _ = writer.drain(&state)

        let work = writer.flush()
        state.items[id] = nil
        _ = writer.drain(&state)
        _ = await work?()

        _ = await writer.flush()?()

        #expect(writes.value.isEmpty, "the entity was deleted after the failed write")
        #expect(deletions.value == [id])
    }

    @Test("A reinsert drained during the failed flush cancels the restored deletion")
    func reinsertBeatsRestoredDeletion() async {
        let writes = SendableBox<[TestEntity]>([])
        let deletions = SendableBox<Set<UUID>>([])
        let attempts = SendableBox(0)

        let writer = StateWriter<TestState>(keyPath: \.items) { w, d in
            attempts.value += 1
            if attempts.value == 1 { throw TestPersistError() }
            writes.value = w
            deletions.value = d
        }

        let id = UUID()
        let restored = TestEntity(id: id, name: "Undone")
        var state = TestState()
        state.items = EntityStore([restored])
        state.items[id] = nil
        _ = writer.drain(&state)

        let work = writer.flush()
        state.items[id] = restored
        _ = writer.drain(&state)
        _ = await work?()

        _ = await writer.flush()?()

        // Same rule the drain path already enforces: carrying both means the
        // delete wins at the database.
        #expect(writes.value == [restored])
        #expect(deletions.value.isEmpty)
    }

    // MARK: - pendingIDs

    @Test("pendingIDs reports drained writes and deletions, and clears on flush")
    func pendingIDsLifecycle() async {
        let writer = Self.makeWriter { _, _ in }
        let written = UUID()
        let deleted = UUID()
        var state = TestState()

        #expect(writer.pendingIDs.isEmpty, "a fresh writer holds nothing")

        state.items[written] = TestEntity(id: written, name: "written")
        state.items[deleted] = TestEntity(id: deleted, name: "doomed")
        _ = writer.drain(&state)
        state.items[deleted] = nil
        _ = writer.drain(&state)

        #expect(writer.pendingIDs == [written, deleted], "drained but not yet on disk")

        if let work = writer.flush() { _ = await work() }
        #expect(writer.pendingIDs.isEmpty, "flushing hands the batch off, so nothing is pending")

        // The window the merge actually cares about: a write drained *after* a
        // flush snapshotted the buffers is pending again.
        let late = UUID()
        state.items[late] = TestEntity(id: late, name: "late")
        _ = writer.drain(&state)
        #expect(writer.pendingIDs == [late])
    }

    @Test("pendingIDs covers a batch whose save failed")
    func pendingIDsCoverFailedBatch() async {
        let writer = StateWriter<TestState>(keyPath: \.items) { _, _ in throw TestPersistError() }

        let written = UUID()
        let deleted = UUID()
        var state = TestState()
        state.items = EntityStore([TestEntity(id: deleted, name: "doomed")])
        state.items[written] = TestEntity(id: written, name: "written")
        state.items[deleted] = nil
        _ = writer.drain(&state)

        _ = await writer.flush()?()

        // This is what stops a merge overwriting memory with the stale stored
        // row: storage has no authority over an ID whose write never landed.
        #expect(writer.pendingIDs == [written, deleted])
    }
}
