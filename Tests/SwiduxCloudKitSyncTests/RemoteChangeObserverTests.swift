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
        try await Task.sleep(for: .milliseconds(300))

        #expect(counter.value == 1)
        observer.stop()
    }

    @MainActor
    @Test("stop() cancels a pending debounced callback")
    func stopCancels() async throws {
        let counter = Counter()
        let observer = RemoteChangeObserver(debounce: .milliseconds(100)) {
            counter.value += 1
        }
        observer.start()

        NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil)
        try await Task.sleep(for: .milliseconds(30))  // let the notification schedule the debounce
        observer.stop()  // cancel before the debounce fires
        try await Task.sleep(for: .milliseconds(250))

        #expect(counter.value == 0)
    }
}
