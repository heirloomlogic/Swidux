//
//  PersistenceMiddlewareTests.swift
//  SwiduxTests
//

import Foundation
import Testing

@testable import Swidux

@Suite("PersistenceMiddleware")
@MainActor
struct PersistenceMiddlewareTests {

    // MARK: - Tests

    @Test("afterReduce with no changes does not schedule a flush")
    func noChangesNoFlush() async throws {
        let flushCount = SendableBox(0)
        let writer = StateWriter<TestState>(
            keyPath: \.items,
            persist: { _, _ in flushCount.value += 1 }
        )
        let middleware = PersistenceMiddleware<TestState>(
            writers: [writer],
            debounce: .milliseconds(10)
        )

        var state = TestState()
        middleware.afterReduce(state: &state)

        // Wait longer than the debounce — nothing should fire
        try await Task.sleep(for: .milliseconds(50))
        #expect(flushCount.value == 0)
    }

    @Test("afterReduce with changes flushes after debounce")
    func changesFlushAfterDebounce() async throws {
        await confirmation(expectedCount: 1) { confirmed in
            let writer = StateWriter<TestState>(
                keyPath: \.items,
                persist: { writes, _ in
                    confirmed()
                }
            )
            let middleware = PersistenceMiddleware<TestState>(
                writers: [writer],
                debounce: .milliseconds(20)
            )

            var state = TestState()
            let entity = TestEntity(name: "Test")
            state.items[entity.id] = entity

            middleware.afterReduce(state: &state)

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
            let middleware = PersistenceMiddleware<TestState>(
                writers: [writer],
                debounce: .milliseconds(50)
            )

            var state = TestState()

            // Fire 5 rapid changes — each restarts the debounce
            for i in 0..<5 {
                let entity = TestEntity(name: "Entity \(i)")
                state.items[entity.id] = entity
                middleware.afterReduce(state: &state)
                try? await Task.sleep(for: .milliseconds(10))
            }

            // Wait for the single debounced flush
            try? await Task.sleep(for: .milliseconds(150))
        }

        #expect(flushCount.value == 1)
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

            let middleware = PersistenceMiddleware<TestState>(
                writers: [writer1, writer2],
                debounce: .milliseconds(20)
            )

            var state = TestState()
            let e1 = TestEntity(name: "Item")
            let e2 = TestEntity(name: "Extra")
            state.items[e1.id] = e1
            state.extras[e2.id] = e2

            middleware.afterReduce(state: &state)

            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
