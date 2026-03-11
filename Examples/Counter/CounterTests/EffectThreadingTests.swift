import Foundation
import Synchronization
import Testing

@testable import Counter

@Suite("Effect Threading")
struct EffectThreadingTests {
    @Test("Effects run off MainActor when dispatched with Task { @concurrent in }")
    @MainActor
    func effectRunsOffMainActor() async throws {
        let wasOnMainThread = Mutex(false)

        let effect: Effect = { send in
            wasOnMainThread.withLock { $0 = Thread.isMainThread }
            await send(.counter(.increment(UUID())))
        }

        Task { @concurrent in
            await effect { _ in }
        }

        try await Task.sleep(for: .milliseconds(50))

        let ranOnMain = wasOnMainThread.withLock { $0 }
        #expect(!ranOnMain, "Effect body should NOT run on the main thread")
    }

    @Test("Send hops back to MainActor from effect")
    @MainActor
    func sendHopsToMainActor() async throws {
        let sendWasOnMain = Mutex(false)

        let effect: Effect = { send in
            await send(.counter(.increment(UUID())))
        }

        let send: Send = { _ in
            sendWasOnMain.withLock { $0 = Thread.isMainThread }
        }

        Task { @concurrent in
            await effect(send)
        }

        try await Task.sleep(for: .milliseconds(50))

        let wasOnMain = sendWasOnMain.withLock { $0 }
        #expect(wasOnMain, "Send should execute on the MainActor")
    }
}
