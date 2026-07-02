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
        let (dispatched, dispatchedIn) = AsyncStream<Void>.makeStream()

        let effect: Effect<TestAction> = { send in
            await send(.effectAction("from background"))
        }

        let send: Send<TestAction> = { action in
            store.send(action)
            dispatchedIn.yield()
        }
        Task { @concurrent in
            try await effect(send)
        }

        // Deterministic: the send closure signals when the action lands.
        var signals = dispatched.makeAsyncIterator()
        await signals.next()

        #expect(store.dispatched.count == 1)
        #expect(store.dispatched.first == .effectAction("from background"))
    }

    @Test("@concurrent runs the effect body off the MainActor")
    @MainActor
    func effectRunsOffMainActor() async throws {
        let wasOnMainThread = Mutex(false)
        let (dispatched, dispatchedIn) = AsyncStream<Void>.makeStream()

        let effect: Effect<TestAction> = { send in
            wasOnMainThread.withLock { $0 = Thread.isMainThread }
            await send(.noOp)
        }

        let store = TestDispatcher()
        let send: Send<TestAction> = { action in
            store.send(action)
            dispatchedIn.yield()
        }
        Task { @concurrent in
            try await effect(send)
        }

        var signals = dispatched.makeAsyncIterator()
        await signals.next()

        let ranOnMain = wasOnMainThread.withLock { $0 }
        #expect(!ranOnMain, "Effect body should NOT run on the main thread")
    }
}
