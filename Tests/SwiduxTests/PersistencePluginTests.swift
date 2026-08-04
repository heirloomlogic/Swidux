//
//  PersistencePluginTests.swift
//  SwiduxTests
//

import Foundation
import Testing

@testable import Swidux

@Suite("PersistencePlugin")
@MainActor
struct PersistencePluginTests {
    // MARK: - Tests

    @Test("afterReduce with no changes does not schedule a flush")
    func noChangesNoFlush() async throws {
        let flushCount = SendableBox(0)
        let writer = StateWriter<TestState>(
            keyPath: \.items,
            persist: { _, _ in flushCount.value += 1 }
        )
        let plugin = PersistencePlugin<TestState, TestAction>(
            writers: [writer],
            debounce: .milliseconds(10)
        )

        var state = TestState()
        plugin.afterReduce(state: &state, action: .noOp)

        // Wait longer than the debounce — nothing should fire
        try await Task.sleep(for: .milliseconds(50))
        #expect(flushCount.value == 0)
    }

    @Test("afterReduce with changes flushes after debounce")
    func changesFlushAfterDebounce() async throws {
        let flushCount = SendableBox(0)
        let writer = StateWriter<TestState>(
            keyPath: \.items,
            persist: { _, _ in flushCount.value += 1 }
        )
        let plugin = PersistencePlugin<TestState, TestAction>(
            writers: [writer],
            debounce: .milliseconds(50)
        )

        var state = TestState()
        let entity = TestEntity(name: "Test")
        state.items[entity.id] = entity

        plugin.afterReduce(state: &state, action: .noOp)

        // Wait for the timer to fire rather than sleeping past it: the subject
        // is that the debounce flushes on its own, not that it does so inside
        // any particular span. `await plugin.flush()` would cancel the timer
        // and test something else.
        try await poll(until: { flushCount.value == 1 }, timeout: .seconds(5))
        #expect(flushCount.value == 1)
    }

    @Test("Rapid calls restart debounce — only one flush")
    func rapidCallsCoalesce() async throws {
        let flushCount = SendableBox(0)
        let debounce = Duration.milliseconds(50)

        let writer = StateWriter<TestState>(
            keyPath: \.items,
            persist: { _, _ in flushCount.value += 1 }
        )
        let plugin = PersistencePlugin<TestState, TestAction>(
            writers: [writer],
            debounce: debounce
        )

        var state = TestState()

        // Fire 5 rapid changes — each restarts the debounce
        for i in 0..<5 {
            let entity = TestEntity(name: "Entity \(i)")
            state.items[entity.id] = entity
            plugin.afterReduce(state: &state, action: .noOp)
        }

        // Two claims, two waits. That the flush happens at all is timing-free:
        // poll until it does, however long the runner takes.
        try await poll(until: { flushCount.value >= 1 }, timeout: .seconds(5))

        // That it happens *once* can only be shown by waiting out further
        // debounce intervals and finding no second flush. A sleep is inherent
        // to asserting absence — but here a slow runner produces a false pass,
        // never the false failure that a sleep-to-observe produces.
        try await Task.sleep(for: debounce * 3)
        #expect(flushCount.value == 1)
    }

    @Test("Explicit flush persists pending writes immediately")
    func explicitFlush() async throws {
        let writesBox = SendableBox<[TestEntity]>([])

        let writer = StateWriter<TestState>(
            keyPath: \.items,
            persist: { writes, _ in writesBox.value = writes }
        )
        let plugin = PersistencePlugin<TestState, TestAction>(
            writers: [writer],
            debounce: .milliseconds(500)  // long debounce — won't fire naturally
        )

        var state = TestState()
        let entity = TestEntity(name: "Urgent")
        state.items[entity.id] = entity
        plugin.afterReduce(state: &state, action: .noOp)

        // Flush immediately — don't wait for debounce
        await plugin.flush()

        #expect(writesBox.value.count == 1)
        #expect(writesBox.value.first?.name == "Urgent")
    }

    @Test("Multiple writers are all flushed")
    func multipleWriters() async throws {
        await confirmation(expectedCount: 2) { confirmed in
            let writer1 = StateWriter<TestState>(
                keyPath: \.items,
                persist: { _, _ in confirmed() }
            )
            let writer2 = StateWriter<TestState>(
                keyPath: \.extras,
                persist: { _, _ in confirmed() }
            )

            let plugin = PersistencePlugin<TestState, TestAction>(
                writers: [writer1, writer2],
                debounce: .milliseconds(50)
            )

            var state = TestState()
            let e1 = TestEntity(name: "Item")
            let e2 = TestEntity(name: "Extra")
            state.items[e1.id] = e1
            state.extras[e2.id] = e2

            plugin.afterReduce(state: &state, action: .noOp)

            // Await the flush rather than sleeping past the debounce: this test
            // is about *every* writer firing, not about timing, and `flush()`
            // awaits each writer's persist closure. Racing a fixed sleep made
            // it flaky on loaded CI — the flush task suspends between writers,
            // so a deschedule there confirmed one of two. Debounce timing is
            // covered by `changesFlushAfterDebounce` and the rapid-calls test.
            await plugin.flush()
        }
    }

    @Test("flush() awaits a debounce flush already in flight")
    func flushAwaitsInflightDebounceFlush() async throws {
        let completedWrites = SendableBox(0)

        let writer = StateWriter<TestState>(
            keyPath: \.items,
            persist: { _, _ in
                // Simulate a slow database write: flush() must not return
                // while this is still running.
                try? await Task.sleep(for: .milliseconds(200))
                completedWrites.value += 1
            }
        )
        let plugin = PersistencePlugin<TestState, TestAction>(
            writers: [writer],
            debounce: .milliseconds(10)
        )

        var state = TestState()
        let entity = TestEntity(name: "Slow")
        state.items[entity.id] = entity
        plugin.afterReduce(state: &state, action: .noOp)

        // Let the debounce fire and enter the slow persist call.
        try await Task.sleep(for: .milliseconds(100))
        #expect(completedWrites.value == 0)

        // Shutdown flush: the buffers are already drained into the in-flight
        // write, so this must wait for it rather than returning immediately.
        await plugin.flush()
        #expect(completedWrites.value == 1)
    }

    @Test("plugin registers with PluginHost and receives lifecycle calls")
    func pluginHostIntegration() async throws {
        let writesBox = SendableBox<[TestEntity]>([])

        let writer = StateWriter<TestState>(
            keyPath: \.items,
            persist: { writes, _ in writesBox.value = writes }
        )
        let plugin = PersistencePlugin<TestState, TestAction>(
            writers: [writer],
            debounce: .milliseconds(500)
        )

        let host = PluginHost<TestState, TestAction>()
        host.register(plugin)

        var state = TestState()
        let entity = TestEntity(name: "Via host")
        state.items[entity.id] = entity
        host.afterReduce(state: &state, action: .noOp)

        await host.flush()

        #expect(writesBox.value.count == 1)
        #expect(writesBox.value.first?.name == "Via host")
    }
}
