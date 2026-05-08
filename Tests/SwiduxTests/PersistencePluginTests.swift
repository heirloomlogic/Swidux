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
        await confirmation(expectedCount: 1) { confirmed in
            let writer = StateWriter<TestState>(
                keyPath: \.items,
                persist: { _, _ in
                    confirmed()
                }
            )
            let plugin = PersistencePlugin<TestState, TestAction>(
                writers: [writer],
                debounce: .milliseconds(20)
            )

            var state = TestState()
            let entity = TestEntity(name: "Test")
            state.items[entity.id] = entity

            plugin.afterReduce(state: &state, action: .noOp)

            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("Rapid calls restart debounce — only one flush")
    func rapidCallsCoalesce() async throws {
        let flushCount = SendableBox(0)

        await confirmation(expectedCount: 1) { confirmed in
            let writer = StateWriter<TestState>(
                keyPath: \.items,
                persist: { _, _ in
                    flushCount.value += 1
                    confirmed()
                }
            )
            let plugin = PersistencePlugin<TestState, TestAction>(
                writers: [writer],
                debounce: .milliseconds(50)
            )

            var state = TestState()

            // Fire 5 rapid changes — each restarts the debounce
            for i in 0..<5 {
                let entity = TestEntity(name: "Entity \(i)")
                state.items[entity.id] = entity
                plugin.afterReduce(state: &state, action: .noOp)
            }

            // Wait for the single debounced flush — generous margin for slow CI runners
            try? await Task.sleep(for: .milliseconds(500))
        }

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
                debounce: .milliseconds(20)
            )

            var state = TestState()
            let e1 = TestEntity(name: "Item")
            let e2 = TestEntity(name: "Extra")
            state.items[e1.id] = e1
            state.extras[e2.id] = e2

            plugin.afterReduce(state: &state, action: .noOp)

            try? await Task.sleep(for: .milliseconds(100))
        }
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
