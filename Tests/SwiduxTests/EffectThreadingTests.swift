//
//  EffectThreadingTests.swift
//  SwiduxTests
//
//  Verifies that runEffect executes effect bodies off the MainActor.
//

import Foundation
import Synchronization
import Testing

@testable import Swidux

// MARK: - Tests

@Suite("Effect Threading")
struct EffectThreadingTests {
    @Test("runEffect dispatches actions back to the store")
    @MainActor
    func effectDispatchesActions() async throws {
        let store = TestDispatcher()

        let effect: Effect<TestAction> = { send in
            await send(.effectAction("from background"))
        }

        let send: Send<TestAction> = { action in
            store.send(action)
        }
        store.runEffect(effect, send: send)

        // Give the concurrent task time to execute
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.dispatched.count == 1)
        #expect(store.dispatched.first == .effectAction("from background"))
    }

    @Test("runEffect runs the effect body off the MainActor")
    @MainActor
    func effectRunsOffMainActor() async throws {
        let store = TestDispatcher()
        let wasOnMainThread = Mutex(false)

        let effect: Effect<TestAction> = { send in
            wasOnMainThread.withLock { $0 = Thread.isMainThread }
            await send(.noOp)
        }

        let send: Send<TestAction> = { action in
            store.send(action)
        }
        store.runEffect(effect, send: send)

        // Give the concurrent task time to execute
        try await Task.sleep(for: .milliseconds(50))

        let ranOnMain = wasOnMainThread.withLock { $0 }
        #expect(!ranOnMain, "Effect body should NOT run on the main thread")
    }
}
