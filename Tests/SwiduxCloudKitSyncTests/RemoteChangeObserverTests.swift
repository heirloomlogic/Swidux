//
//  RemoteChangeObserverTests.swift
//  SwiduxCloudKitSyncTests
//
//  Verifies the debounced remote-change observer coalesces bursts and that
//  stop() cancels a pending callback.
//

import Foundation
import Testing

@testable import SwiduxCloudKitSync

@Suite("RemoteChangeObserver")
struct RemoteChangeObserverTests {
    @MainActor
    final class Counter {
        var value = 0
    }

    /// Polls `condition` on the main actor until it holds or the cap elapses.
    /// Notification delivery is async, so tests wait for an observable state
    /// rather than a fixed sleep that races CI scheduling.
    @MainActor
    private func poll(
        until condition: () -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        var waited = Duration.zero
        while !condition(), waited < timeout {
            try await Task.sleep(for: .milliseconds(10))
            waited += .milliseconds(10)
        }
    }

    @MainActor
    @Test("a burst of remote-change notifications coalesces into one callback")
    func coalesces() async throws {
        let counter = Counter()
        let observer = RemoteChangeObserver(debounce: .milliseconds(80)) {
            counter.value += 1
        }
        observer.start()

        for _ in 0..<3 {
            NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil)
        }

        // Wait for the coalesced callback to fire, then confirm it fired exactly once.
        try await poll(until: { counter.value >= 1 })
        try await Task.sleep(for: .milliseconds(120))  // > debounce; catch any second fire

        #expect(counter.value == 1)
        observer.stop()
    }

    @MainActor
    @Test("stop() cancels a pending debounced callback")
    func stopCancels() async throws {
        let counter = Counter()
        // A long debounce so the merge is comfortably still armed (not fired) by
        // the time we observe it and call stop().
        let observer = RemoteChangeObserver(debounce: .seconds(1)) {
            counter.value += 1
        }
        observer.start()

        NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil)

        // Wait until the async notification has actually armed the debounce, rather
        // than guessing a delay — otherwise stop() can run before the block does,
        // and an already-enqueued notification still schedules a merge afterward.
        try await poll(until: { observer.hasScheduledMerge })
        #expect(observer.hasScheduledMerge, "the notification should have armed a debounced merge")

        observer.stop()  // cancel the armed merge before its (1s) debounce fires
        try await Task.sleep(for: .milliseconds(150))  // a cancelled callback must not fire

        #expect(counter.value == 0)
    }
}
