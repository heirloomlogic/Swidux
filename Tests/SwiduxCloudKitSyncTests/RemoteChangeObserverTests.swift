//
//  RemoteChangeObserverTests.swift
//  SwiduxCloudKitSyncTests
//
//  Verifies the debounced remote-change observer coalesces bursts into one
//  payload that names every store it accepted, filters out stores it doesn't
//  own without ever silencing one it can't identify, and that stop() cancels a
//  pending callback.
//
//  Every test drives its own `NotificationCenter` rather than the default one.
//  `.NSPersistentStoreRemoteChange` is posted process-wide, and this bundle's
//  `SyncCoordinator` suite saves through real `ModelContainer`s in parallel —
//  so on the shared center a burst here also picks up that suite's saves, and
//  no assertion about how many notifications a burst held can be stable.
//

import CoreData
import Foundation
import Testing

@testable import SwiduxCloudKitSync

@Suite("RemoteChangeObserver")
struct RemoteChangeObserverTests {
    /// A store URL that never exists — nothing here opens one. The paths are
    /// already standardized, so they survive the observer's normalization
    /// unchanged and compare as written.
    static func store(_ name: String) -> URL {
        URL(fileURLWithPath: "/swidux/tests/\(name).store")
    }

    /// A store the observer owns, and one it doesn't.
    static let ours = store("ours")
    static let theirs = store("theirs")

    @MainActor
    final class Recorder {
        var changes: [RemoteChange] = []
    }

    /// An observer wired to its own notification center and recorder.
    ///
    /// Started by the caller, not here, so a test can post before `start()` or
    /// restart it mid-test.
    @MainActor
    private func makeObserver(
        debounce: Duration = .milliseconds(80),
        owning owned: Set<URL>? = nil
    ) -> (observer: RemoteChangeObserver, center: NotificationCenter, recorder: Recorder) {
        let center = NotificationCenter()
        let recorder = Recorder()
        var identity: RemoteChangeObserver.StoreIdentity?
        if let owned { identity = { owned } }
        let observer = RemoteChangeObserver(
            debounce: debounce,
            ownedStoreURLs: identity,
            notificationCenter: center
        ) { change in
            recorder.changes.append(change)
        }
        return (observer, center, recorder)
    }

    /// Posts one `.NSPersistentStoreRemoteChange` carrying the `userInfo`
    /// CoreData would attach. Omitting both keys is the unidentifiable case.
    private func post(
        to center: NotificationCenter,
        storeURL: URL? = nil,
        storeUUID: String? = nil
    ) {
        var userInfo: [AnyHashable: Any] = [:]
        if let storeURL { userInfo[NSPersistentStoreURLKey] = storeURL }
        if let storeUUID { userInfo[NSStoreUUIDKey] = storeUUID }
        center.post(
            name: .NSPersistentStoreRemoteChange,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
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
    @Test("a burst coalesces into one callback naming every store it saw")
    func coalesces() async throws {
        let (observer, center, recorder) = makeObserver()
        observer.start()
        defer { observer.stop() }

        let urls = (0..<3).map { Self.store("store-\($0)") }
        for url in urls { post(to: center, storeURL: url) }

        // Wait for the coalesced callback to fire, then confirm it fired exactly once.
        try await poll(until: { !recorder.changes.isEmpty })
        try await Task.sleep(for: .milliseconds(120))  // > debounce; catch any second fire

        #expect(recorder.changes.count == 1)
        let change = try #require(recorder.changes.first)
        // The union of the burst, not whichever notification happened to be last.
        #expect(change.storeURLs == Set(urls))
        #expect(change.notificationCount == 3)
        #expect(!change.includesUnidentifiedStore)
    }

    @MainActor
    @Test("with no store identity configured, every store still merges")
    func withoutIdentityEverythingMerges() async throws {
        // No owned set — the default, and the pre-existing behaviour.
        let (observer, center, recorder) = makeObserver()
        observer.start()
        defer { observer.stop() }

        post(to: center, storeURL: Self.theirs)

        try await poll(until: { !recorder.changes.isEmpty })
        let change = try #require(recorder.changes.first)
        #expect(change.storeURLs == [Self.theirs])
        #expect(change.notificationCount == 1)
    }

    @MainActor
    @Test("an observer dropped without stop() deallocates, and its center outlives it safely")
    func droppedObserverDeallocates() async throws {
        let center = NotificationCenter()
        weak var leaked: RemoteChangeObserver?

        do {
            let observer = RemoteChangeObserver(
                debounce: .milliseconds(10), notificationCenter: center
            ) { _ in }
            observer.start()
            leaked = observer
            #expect(leaked != nil)
        }

        // The center retains the block `start()` handed it. That block captures
        // `self` weakly, so the observer still dies — this pins that capture,
        // which a future edit could turn into a cycle without any other signal.
        #expect(leaked == nil, "the notification registration must not retain the observer")

        // And the registration itself is gone: posting afterwards reaches a
        // center holding nothing of ours. `deinit` is the only place that can
        // remove the token when the owner forgot to `stop()`.
        post(to: center, storeURL: Self.ours)
        try await Task.sleep(for: .milliseconds(30))
    }

    @MainActor
    @Test("a notification from an unidentifiable store still triggers a merge")
    func unidentifiedStoreStillMerges() async throws {
        let (observer, center, recorder) = makeObserver(owning: [Self.ours])
        observer.start()
        defer { observer.stop() }

        post(to: center)  // no userInfo at all — identity unavailable

        try await poll(until: { !recorder.changes.isEmpty })
        let change = try #require(recorder.changes.first)
        #expect(change.includesUnidentifiedStore, "an unidentifiable store must never be filtered out")
        #expect(change.storeURLs.isEmpty)
        #expect(change.notificationCount == 1)
    }

    @MainActor
    @Test("a burst mixing owned and foreign stores merges only what the observer owns")
    func foreignStoresFilteredOut() async throws {
        let (observer, center, recorder) = makeObserver(owning: [Self.ours])
        observer.start()
        defer { observer.stop() }

        // The foreign posts go first, so the owned one arriving proves they were
        // delivered and dropped rather than merely still in flight.
        post(to: center, storeURL: Self.theirs)
        post(to: center, storeURL: Self.theirs)
        post(to: center, storeURL: Self.ours, storeUUID: "OURS-UUID")

        try await poll(until: { !recorder.changes.isEmpty })
        try await Task.sleep(for: .milliseconds(120))

        #expect(recorder.changes.count == 1)
        let change = try #require(recorder.changes.first)
        #expect(change.storeURLs == [Self.ours])
        #expect(change.storeUUIDs == ["OURS-UUID"])
        #expect(change.notificationCount == 1, "the two foreign notifications must not be counted")
        #expect(!change.includesUnidentifiedStore)
    }

    @MainActor
    @Test("a foreign notification doesn't push out a merge that's already armed")
    func foreignDoesNotRearm() async throws {
        // A long debounce so the armed merge is comfortably still pending.
        let (observer, center, _) = makeObserver(debounce: .seconds(1), owning: [Self.ours])
        observer.start()
        defer { observer.stop() }

        post(to: center, storeURL: Self.ours)
        try await poll(until: { observer.armedMergeCount == 1 })

        for _ in 0..<3 { post(to: center, storeURL: Self.theirs) }
        // Give the foreign posts room to land, then confirm none of them re-armed.
        // Left as a poll rather than a sleep: it can only end early on failure.
        try await poll(until: { observer.armedMergeCount > 1 }, timeout: .milliseconds(200))

        #expect(
            observer.armedMergeCount == 1,
            "a store the observer doesn't own must not restart the debounce"
        )
    }

    @MainActor
    @Test("stop() cancels a pending debounced callback")
    func stopCancels() async throws {
        // A long debounce so the merge is comfortably still armed (not fired) by
        // the time we observe it and call stop().
        let (observer, center, recorder) = makeObserver(debounce: .seconds(1))
        observer.start()

        post(to: center, storeURL: Self.ours)

        // Wait until the async notification has actually armed the debounce, rather
        // than guessing a delay — otherwise stop() can run before the block does,
        // and an already-enqueued notification still schedules a merge afterward.
        try await poll(until: { observer.hasScheduledMerge })
        #expect(observer.hasScheduledMerge, "the notification should have armed a debounced merge")

        observer.stop()  // cancel the armed merge before its (1s) debounce fires
        try await Task.sleep(for: .milliseconds(150))  // a cancelled callback must not fire

        #expect(recorder.changes.isEmpty)
    }

    @MainActor
    @Test("stop() discards the burst it had accumulated")
    func stopDiscardsAccumulatedBurst() async throws {
        // A long debounce so stop() lands while the first burst is still armed —
        // an 80ms one could fire before the poll below observes it.
        let (observer, center, recorder) = makeObserver(debounce: .seconds(1))
        observer.start()

        post(to: center, storeURL: Self.theirs)
        try await poll(until: { observer.hasScheduledMerge })
        observer.stop()

        // Restarting must not inherit the stopped burst's stores.
        observer.start()
        defer { observer.stop() }
        post(to: center, storeURL: Self.ours)

        try await poll(until: { !recorder.changes.isEmpty })
        let change = try #require(recorder.changes.first)
        #expect(change.storeURLs == [Self.ours])
        #expect(change.notificationCount == 1)
    }
}
