//
//  EffectThreadingTests.swift
//  SwiduxTests
//
//  Verifies that effects dispatched with Task { @concurrent in }
//  execute off the MainActor.
//

import Foundation
import Synchronization
import Testing

@testable import Swidux

// MARK: - Tests

@Suite("Effect Threading")
struct EffectThreadingTests {
    @Test("Effect dispatches actions back via send")
    @MainActor
    func effectDispatchesActions() async throws {
        let store = TestDispatcher()

        let effect: Effect<TestAction> = { send in
            await send(.effectAction("from background"))
        }

        let send: Send<TestAction> = { action in
            store.send(action)
        }
        Task { @concurrent in
            await effect(send)
        }

        try await Task.sleep(for: .milliseconds(50))

        #expect(store.dispatched.count == 1)
        #expect(store.dispatched.first == .effectAction("from background"))
    }

    @Test("@concurrent runs the effect body off the MainActor")
    @MainActor
    func effectRunsOffMainActor() async throws {
        let wasOnMainThread = Mutex(false)

        let effect: Effect<TestAction> = { send in
            wasOnMainThread.withLock { $0 = Thread.isMainThread }
            await send(.noOp)
        }

        let store = TestDispatcher()
        let send: Send<TestAction> = { action in
            store.send(action)
        }
        Task { @concurrent in
            await effect(send)
        }

        try await Task.sleep(for: .milliseconds(50))

        let ranOnMain = wasOnMainThread.withLock { $0 }
        #expect(!ranOnMain, "Effect body should NOT run on the main thread")
    }
}
