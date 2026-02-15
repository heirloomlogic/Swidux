//
//  SwiduxDispatcherTests.swift
//  SwiduxTests
//

import Foundation
import Testing

@testable import Swidux

// MARK: - Concrete Test Dispatcher

/// Minimal dispatcher that records dispatched actions for verification.
final class TestDispatcher: SwiduxDispatcher {
    nonisolated private(set) var dispatched: [TestAction] = []

    nonisolated func send(_ action: TestAction) {
        dispatched.append(action)
    }
}

// MARK: - Tests

@Suite("SwiduxDispatcher")
struct SwiduxDispatcherTests {

    @Test("Send records dispatched actions in order")
    func sendRecordsActions() {
        let dispatcher = TestDispatcher()

        dispatcher.send(.noOp)
        dispatcher.send(.insert(TestEntity(name: "Test")))
        dispatcher.send(.delete(UUID()))

        #expect(dispatcher.dispatched.count == 3)
        #expect(dispatcher.dispatched[0] == .noOp)
    }

    @Test("Dispatcher can be used with effect Send typealias")
    @MainActor
    func sendTypealias() async {
        let dispatcher = TestDispatcher()

        // Use the Send typealias to dispatch
        let send: Send<TestAction> = { action in
            dispatcher.send(action)
        }

        send(.effectAction("from effect"))

        #expect(dispatcher.dispatched.count == 1)
        #expect(dispatcher.dispatched.first == .effectAction("from effect"))
    }
}
