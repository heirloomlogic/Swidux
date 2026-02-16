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
}

@Suite("StateWriter")
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
            await work()
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
            await work()
        }

        #expect(writesBox.value.isEmpty)
        #expect(deletionsBox.value.contains(entity.id))
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
        await work!()

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
            await work()
        }

        #expect(writesBox.value.count == 1)
        #expect(writesBox.value.first?.name == "Second")
    }
}
