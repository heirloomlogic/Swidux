import Foundation
import Testing

@testable import Swidux

@Suite("Overlapping persistence flushes")
@MainActor
struct PersistenceOverlapTests {
    @Test("A failed older batch cannot overwrite a queued edit or deletion", arguments: [false, true])
    func newerIntentWins(deleting: Bool) async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let disk = SendableBox<[UUID: TestEntity]>([:])
        let attempts = SendableBox(0)
        let writer = StateWriter<TestState>(keyPath: \.items) { writes, deletions in
            attempts.withValue { $0 += 1 }
            if attempts.value == 1 {
                started.continuation.yield()
                for await _ in release.stream { break }
                throw TestPersistError()
            }
            disk.withValue { values in
                for entity in writes { values[entity.id] = entity }
                for id in deletions { values.removeValue(forKey: id) }
            }
        }
        let plugin = PersistencePlugin<TestState, TestAction>(
            writers: [writer], debounce: .seconds(60), retry: .never)
        let entity = TestEntity(name: "old")
        var state = TestState()
        state.items[entity.id] = entity
        plugin.drainAndScheduleFlush(&state)
        let first = Task { await plugin.flush() }
        for await _ in started.stream { break }

        state.items[entity.id] = deleting ? nil : TestEntity(id: entity.id, name: "new")
        plugin.drainAndScheduleFlush(&state)
        // The task signals after flush has synchronously queued its work and suspended.
        let queued = AsyncStream<Void>.makeStream()
        let second = Task {
            queued.continuation.yield()
            await plugin.flush()
        }
        for await _ in queued.stream { break }
        release.continuation.yield()
        await first.value
        await second.value
        await plugin.flush()

        #expect(writer.pendingIDs.isEmpty)
        #expect(disk.value[entity.id]?.name == (deleting ? nil : "new"))
    }
}
