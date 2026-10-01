//
//  FeatureFlagsPluginTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Swidux
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsPlugin")
@MainActor
struct FeatureFlagsPluginTests {
    @Test("Repeated refreshes share the in-flight request", arguments: [RefreshPolicy.manual, .automatic])
    func refreshDoesNotOverlap(_ policy: RefreshPolicy) {
        let plugin = makePlugin(refreshPolicy: policy)
        var state = TestState()
        #expect(plugin.reduce(state: &state, action: .featureFlags(.refresh)) != nil)
        #expect(plugin.reduce(state: &state, action: .featureFlags(.refresh)) == nil)
        _ = plugin.reduce(state: &state, action: .featureFlags(.refreshFailed("offline")))
        #expect(plugin.reduce(state: &state, action: .featureFlags(.refresh)) != nil)
    }

    // MARK: - Test fixtures

    struct TestState: Sendable, Equatable {
        var featureFlags = FeatureFlagsState()
        var deviceID: String = "device-1"
        var userID: String? = nil
    }

    enum TestAction: Sendable, Equatable {
        case featureFlags(FeatureFlagsAction)
        case unrelated
    }

    func makePlugin(
        service: any FeatureFlagsService = MockFeatureFlagsService(outcome: .success(.empty)),
        deviceIDKeyPath: KeyPath<TestState, String> = \.deviceID,
        userIDKeyPath: KeyPath<TestState, String?>? = nil,
        refreshPolicy: RefreshPolicy = .manual,
        keyValueStore: any KeyValueStore = InMemoryKeyValueStore(),
        onExposure: (@Sendable (String, FlagValue) -> Void)? = nil,
        fetchTimeout: Duration = .seconds(30)
    ) -> FeatureFlagsPlugin<TestState, TestAction> {
        FeatureFlagsPlugin(
            state: \.featureFlags,
            action: TestAction.featureFlags,
            extractAction: {
                if case .featureFlags(let a) = $0 { return a }
                return nil
            },
            service: service,
            deviceIDKeyPath: deviceIDKeyPath,
            userIDKeyPath: userIDKeyPath,
            refreshPolicy: refreshPolicy,
            keyValueStore: keyValueStore,
            onExposure: onExposure,
            fetchTimeout: fetchTimeout
        )
    }

    // MARK: - .refresh

    @Test(".refresh hits the service and dispatches refreshSucceeded")
    func refreshSuccess() async throws {
        let config = FeatureFlagsConfig(version: 1, flags: ["f": .boolean(rollout: 50)])
        let service = MockFeatureFlagsService(outcome: .success(config))
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        #expect(state.featureFlags.isFetching)

        var dispatched: [TestAction] = []
        try await effect?({ action in dispatched.append(action) })

        #expect(service.fetchCount == 1)
        #expect(dispatched.count == 1)
        guard case .featureFlags(.refreshSucceeded(let received, _)) = dispatched[0] else {
            Issue.record("expected refreshSucceeded")
            return
        }
        #expect(received == config)
    }

    @Test(".refresh dispatches refreshFailed on service error")
    func refreshFailure() async throws {
        let service = MockFeatureFlagsService(outcome: .failure(URLError(.notConnectedToInternet)))
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        var dispatched: [TestAction] = []
        try await effect?({ action in dispatched.append(action) })

        #expect(dispatched.count == 1)
        guard case .featureFlags(.refreshFailed) = dispatched[0] else {
            Issue.record("expected refreshFailed")
            return
        }
    }

    @Test(".refreshSucceeded updates state with new config and clears isFetching")
    func refreshSucceededUpdatesState() {
        let plugin = makePlugin()
        var state = TestState()
        state.featureFlags.isFetching = true
        let config = FeatureFlagsConfig(version: 1, flags: ["x": .boolean(rollout: 100)])
        let now = Date()

        _ = plugin.reduce(
            state: &state,
            action: .featureFlags(.refreshSucceeded(config, fetchedAt: now))
        )

        #expect(state.featureFlags.config == config)
        #expect(state.featureFlags.lastFetchedAt == now)
        #expect(state.featureFlags.isFetching == false)
        #expect(state.featureFlags.lastFetchError == nil)
    }

    @Test(".refreshFailed records error message and clears isFetching")
    func refreshFailedUpdatesState() {
        let plugin = makePlugin()
        var state = TestState()
        state.featureFlags.isFetching = true

        _ = plugin.reduce(state: &state, action: .featureFlags(.refreshFailed("boom")))

        #expect(state.featureFlags.isFetching == false)
        #expect(state.featureFlags.lastFetchError == "boom")
    }

    @Test("automatic policy debounces refresh inside minInterval")
    func automaticDebounce() async throws {
        let service = MockFeatureFlagsService(outcome: .success(.empty))
        let plugin = makePlugin(service: service, refreshPolicy: .automatic(minInterval: 300))
        var state = TestState()
        state.featureFlags.lastFetchedAt = Date()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        try await effect?({ _ in })

        #expect(service.fetchCount == 0)
    }

    @Test("automatic policy refreshes when lastFetchedAt is in the future (clock skew)")
    func automaticRefreshesOnClockSkew() async throws {
        let service = MockFeatureFlagsService(outcome: .success(.empty))
        let plugin = makePlugin(service: service, refreshPolicy: .automatic(minInterval: 300))
        var state = TestState()
        // A wall clock rolled backward leaves lastFetchedAt in the future;
        // that must count as expired, not starve refreshes for the skew.
        state.featureFlags.lastFetchedAt = Date(timeIntervalSinceNow: 3600)

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        try await effect?({ _ in })

        #expect(service.fetchCount == 1)
    }

    @Test("a service that never returns can't latch isFetching for the session")
    func hungServiceDoesNotLatchIsFetching() async throws {
        let plugin = makePlugin(service: HangingFeatureFlagsService(), fetchTimeout: .milliseconds(50))
        var state = TestState()

        let effect = try #require(plugin.reduce(state: &state, action: .featureFlags(.refresh)))
        var dispatched: [TestAction] = []
        Task { try? await effect { dispatched.append($0) } }
        var waited = Duration.zero
        while dispatched.isEmpty, waited < .seconds(2) {
            try await Task.sleep(for: .milliseconds(5))
            waited += .milliseconds(5)
        }

        guard case .featureFlags(let failure)? = dispatched.first, case .refreshFailed = failure else {
            Issue.record("expected refreshFailed once the fetch timed out, got \(dispatched)")
            return
        }
        _ = plugin.reduce(state: &state, action: .featureFlags(failure))
        #expect(!state.featureFlags.isFetching)
        #expect(plugin.reduce(state: &state, action: .featureFlags(.refresh)) != nil)
    }

    @Test("cancelling the refresh effect reports a failure even if the service ignores it")
    func cancelledRefreshOfHungServiceReportsFailure() async throws {
        let plugin = makePlugin(service: HangingFeatureFlagsService(), fetchTimeout: .seconds(30))
        var state = TestState()

        let effect = try #require(plugin.reduce(state: &state, action: .featureFlags(.refresh)))
        var dispatched: [TestAction] = []
        let running = Task { try? await effect { dispatched.append($0) } }
        try await Task.sleep(for: .milliseconds(20))
        running.cancel()
        var waited = Duration.zero
        while dispatched.isEmpty, waited < .seconds(2) {
            try await Task.sleep(for: .milliseconds(5))
            waited += .milliseconds(5)
        }

        guard case .featureFlags(.refreshFailed)? = dispatched.first else {
            Issue.record("expected refreshFailed after cancellation, got \(dispatched)")
            return
        }
    }

    @Test("manual policy never debounces")
    func manualNeverDebounces() async throws {
        let service = MockFeatureFlagsService(outcome: .success(.empty))
        let plugin = makePlugin(service: service, refreshPolicy: .manual)
        var state = TestState()
        state.featureFlags.lastFetchedAt = Date()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        try await effect?({ _ in })

        #expect(service.fetchCount == 1)
    }

    // MARK: - Overrides

    @Test("setLocalOverride writes into state")
    func setLocalOverride() {
        let plugin = makePlugin()
        var state = TestState()

        _ = plugin.reduce(
            state: &state,
            action: .featureFlags(.setLocalOverride(key: "k", value: .bool(true)))
        )

        #expect(state.featureFlags.localOverrides["k"] == .bool(true))
    }

    @Test("clearLocalOverride removes a single key")
    func clearLocalOverride() {
        let plugin = makePlugin()
        var state = TestState()
        state.featureFlags.localOverrides = ["a": .bool(true), "b": .int(1)]

        _ = plugin.reduce(state: &state, action: .featureFlags(.clearLocalOverride(key: "a")))

        #expect(state.featureFlags.localOverrides == ["b": .int(1)])
    }

    @Test("clearAllLocalOverrides empties the map")
    func clearAllLocalOverrides() {
        let plugin = makePlugin()
        var state = TestState()
        state.featureFlags.localOverrides = ["a": .bool(true)]

        _ = plugin.reduce(state: &state, action: .featureFlags(.clearAllLocalOverrides))

        #expect(state.featureFlags.localOverrides.isEmpty)
    }

    // MARK: - Exposure

    @Test("recordExposure records the value and fires onExposure once")
    func recordExposureFiresOnce() async throws {
        let counter = ExposureCounter()
        let plugin = makePlugin(onExposure: { key, value in
            Task { @MainActor in counter.record(key: key, value: value) }
        })
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(
            version: 1,
            flags: ["k": .boolean(rollout: 100)]
        )

        let effect1 = plugin.reduce(state: &state, action: .featureFlags(.recordExposure(of: BoolFlag("k"))))
        try await effect1?({ _ in })
        await Task.yield()

        #expect(state.featureFlags.exposedValues["k"] != nil)
        #expect(counter.count == 1)

        let effect2 = plugin.reduce(state: &state, action: .featureFlags(.recordExposure(of: BoolFlag("k"))))
        try await effect2?({ _ in })
        await Task.yield()

        #expect(counter.count == 1)
    }

    // MARK: - Identity resolution (userIDKeyPath)

    @Test("afterReduce resolves deviceID and userIDKeyPath into state for default bucketing")
    func userIDKeyPathResolution() {
        let plugin = makePlugin(userIDKeyPath: \.userID)
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(
            version: 1,
            flags: ["k": .boolean(rollout: 50)]
        )

        // Signed out: bucketing falls back to the resolved device ID.
        plugin.afterReduce(state: &state, action: .unrelated)
        #expect(state.featureFlags.resolvedUserID == nil)
        #expect(state.featureFlags.resolvedDeviceID == "device-1")
        #expect(
            state.featureFlags.isEnabled(.init("k"))
                == (Bucketing.bucket(id: "device-1", flagKey: "k") < 5_000)
        )

        // Sign-in: the next dispatch resolves the user ID; default reads use it.
        state.userID = "user-1"
        plugin.afterReduce(state: &state, action: .unrelated)
        #expect(state.featureFlags.resolvedUserID == "user-1")
        #expect(
            state.featureFlags.isEnabled(.init("k"))
                == (Bucketing.bucket(id: "user-1", flagKey: "k") < 5_000)
        )

        // Sign-out clears it again.
        state.userID = nil
        plugin.afterReduce(state: &state, action: .unrelated)
        #expect(state.featureFlags.resolvedUserID == nil)
    }

    @Test("exposure records bucket by the same identity as default reads")
    func exposureUsesResolvedIdentity() async throws {
        let counter = ExposureCounter()
        let plugin = makePlugin(
            userIDKeyPath: \.userID,
            onExposure: { key, value in
                Task { @MainActor in counter.record(key: key, value: value) }
            }
        )
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(
            version: 1,
            flags: ["k": .boolean(rollout: 50)]
        )
        state.userID = "user-1"
        plugin.afterReduce(state: &state, action: .unrelated)

        let effect = plugin.reduce(state: &state, action: .featureFlags(.recordExposure(of: BoolFlag("k"))))
        try await effect?({ _ in })
        await Task.yield()

        let expected = Bucketing.bucket(id: "user-1", flagKey: "k") < 5_000
        #expect(counter.records.first?.1 == .bool(expected))
    }

    @Test("recordExposure with a programmatically-built empty variant set does not trap")
    func recordExposureEmptyVariants() async throws {
        let counter = ExposureCounter()
        let plugin = makePlugin(onExposure: { key, value in
            Task { @MainActor in counter.record(key: key, value: value) }
        })
        var state = TestState()
        // Bypasses decode validation — built in code, not from the wire.
        state.featureFlags.config = FeatureFlagsConfig(
            version: 1,
            flags: ["k": .variant(variants: [])]
        )

        let flag = VariantFlag<Checkout>("k", default: .control)
        let effect = plugin.reduce(state: &state, action: .featureFlags(.recordExposure(of: flag)))
        try await effect?({ _ in })
        await Task.yield()

        #expect(counter.count == 0)
    }

    @Test("recordExposure for unknown key does not fire callback")
    func recordExposureUnknownKey() async throws {
        let counter = ExposureCounter()
        let plugin = makePlugin(onExposure: { key, value in
            Task { @MainActor in counter.record(key: key, value: value) }
        })
        var state = TestState()

        let effect = plugin.reduce(
            state: &state,
            action: .featureFlags(.recordExposure(of: BoolFlag("nope")))
        )
        try await effect?({ _ in })
        await Task.yield()

        #expect(counter.count == 0)
        #expect(state.featureFlags.exposedValues["nope"] == nil)
    }

    // MARK: - Exposure matches the read

    enum Checkout: String { case control, treatment }

    /// Records exposures synchronously so assertions need no yield.
    private func exposurePlugin(
        _ log: ExposureLog,
        userIDKeyPath: KeyPath<TestState, String?>? = nil
    ) -> FeatureFlagsPlugin<TestState, TestAction> {
        makePlugin(userIDKeyPath: userIDKeyPath, onExposure: { key, value in log.append(key, value) })
    }

    private func record(
        _ action: FeatureFlagsAction,
        with plugin: FeatureFlagsPlugin<TestState, TestAction>,
        in state: inout TestState
    ) async throws {
        try await plugin.reduce(state: &state, action: .featureFlags(action))?({ _ in })
    }

    /// First ID in `candidates` whose bucket for `key` lands on the other side
    /// of `threshold` from `id`'s.
    private func idOnOtherSide(of id: String, key: String, threshold: Int = 5_000) -> String {
        let side = Bucketing.bucket(id: id, flagKey: key) < threshold
        let other = (0..<1_000).map { "other-\($0)" }
            .first { (Bucketing.bucket(id: $0, flagKey: key) < threshold) != side }
        guard let other else {
            Issue.record("no candidate ID buckets on the other side of \(threshold) for \(key)")
            return id
        }
        return other
    }

    @Test("a remote variant the app can't parse renders the default and records no exposure")
    func unparseableVariantRecordsNoExposure() async throws {
        let log = ExposureLog()
        let plugin = exposurePlugin(log)
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(
            version: 1,
            flags: ["checkout": .variant(variants: [.init(value: "v3", weight: 100)])]
        )
        let flag = VariantFlag<Checkout>("checkout", default: .control)

        #expect(state.featureFlags.variant(of: flag) == .control)
        try await record(.recordExposure(of: flag), with: plugin, in: &state)

        #expect(log.all.isEmpty)
    }

    @Test("an override the read ignores is not what the exposure records")
    func wrongTypedOverrideRecordsRenderedValue() async throws {
        let log = ExposureLog()
        let plugin = exposurePlugin(log)
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(
            version: 1,
            flags: ["k": .boolean(rollout: 100)]
        )
        state.featureFlags.localOverrides = ["k": .string("off")]

        #expect(state.featureFlags.isEnabled(BoolFlag("k")))
        try await record(.recordExposure(of: BoolFlag("k")), with: plugin, in: &state)

        #expect(log.all.map(\.value) == [.bool(true)])
    }

    @Test("a parseable variant override is recorded as shown")
    func variantOverrideRecorded() async throws {
        let log = ExposureLog()
        let plugin = exposurePlugin(log)
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(
            version: 1,
            flags: ["checkout": .variant(variants: [.init(value: "control", weight: 100)])]
        )
        state.featureFlags.localOverrides = ["checkout": .string("treatment")]
        let flag = VariantFlag<Checkout>("checkout", default: .control)

        try await record(.recordExposure(of: flag), with: plugin, in: &state)

        #expect(log.all.map(\.value) == [.string("treatment")])
    }

    @Test("an exposure buckets by the same explicit bucketingID as the read")
    func exposureHonorsExplicitBucketingID() async throws {
        let log = ExposureLog()
        let plugin = exposurePlugin(log)
        var state = TestState()
        plugin.afterReduce(state: &state, action: .unrelated)
        state.featureFlags.config = FeatureFlagsConfig(
            version: 1,
            flags: ["k": .boolean(rollout: 50)]
        )
        let team = idOnOtherSide(of: "device-1", key: "k")
        let shown = state.featureFlags.isEnabled(BoolFlag("k"), bucketingID: team)

        try await record(.recordExposure(of: BoolFlag("k"), bucketingID: team), with: plugin, in: &state)

        #expect(shown != state.featureFlags.isEnabled(BoolFlag("k")))
        #expect(log.all.map(\.value) == [.bool(shown)])
    }

    // MARK: - Exposure dedupe

    @Test("a reassignment at sign-in records the new variant")
    func reassignmentAtSignInReRecords() async throws {
        let log = ExposureLog()
        let plugin = exposurePlugin(log, userIDKeyPath: \.userID)
        var state = TestState()
        plugin.afterReduce(state: &state, action: .unrelated)
        state.featureFlags.config = FeatureFlagsConfig(
            version: 1,
            flags: [
                "checkout": .variant(variants: [
                    .init(value: "control", weight: 50), .init(value: "treatment", weight: 50),
                ])
            ]
        )
        let flag = VariantFlag<Checkout>("checkout", default: .control)

        let before = state.featureFlags.variant(of: flag)
        try await record(.recordExposure(of: flag), with: plugin, in: &state)
        state.userID = idOnOtherSide(of: "device-1", key: "checkout")
        plugin.afterReduce(state: &state, action: .unrelated)
        let after = state.featureFlags.variant(of: flag)
        try await record(.recordExposure(of: flag), with: plugin, in: &state)
        try await record(.recordExposure(of: flag), with: plugin, in: &state)

        #expect(before != after)
        #expect(log.all.map(\.value) == [.string(before.rawValue), .string(after.rawValue)])
    }

    @Test("a config change that flips the rendered value records it once")
    func configChangeReRecords() async throws {
        let log = ExposureLog()
        let plugin = exposurePlugin(log)
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(version: 1, flags: ["k": .boolean(rollout: 0)])

        try await record(.recordExposure(of: BoolFlag("k")), with: plugin, in: &state)
        let ramped = FeatureFlagsConfig(version: 1, flags: ["k": .boolean(rollout: 100)])
        _ = plugin.reduce(state: &state, action: .featureFlags(.refreshSucceeded(ramped, fetchedAt: Date())))
        try await record(.recordExposure(of: BoolFlag("k")), with: plugin, in: &state)
        try await record(.recordExposure(of: BoolFlag("k")), with: plugin, in: &state)

        #expect(log.all.map(\.value) == [.bool(false), .bool(true)])
    }

    @Test("alternating identities record each rendered value once per session")
    func alternatingIdentitiesRecordEachValueOnce() async throws {
        let log = ExposureLog()
        let plugin = exposurePlugin(log)
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(version: 1, flags: ["k": .boolean(rollout: 50)])
        let account = idOnOtherSide(of: "device-1", key: "k")
        plugin.afterReduce(state: &state, action: .unrelated)

        // One view buckets by account, another by the default identity; both
        // re-appear several times in a session.
        for _ in 0..<3 {
            try await record(.recordExposure(of: BoolFlag("k"), bucketingID: account), with: plugin, in: &state)
            try await record(.recordExposure(of: BoolFlag("k")), with: plugin, in: &state)
        }

        #expect(log.all.count == 2, "recorded \(log.all.map(\.value))")
        #expect(Set(log.all.map(\.value)) == [.bool(true), .bool(false)])
    }

    @Test("toggling a QA override back and forth records each value once")
    func toggledOverrideRecordsEachValueOnce() async throws {
        let log = ExposureLog()
        let plugin = exposurePlugin(log)
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(version: 1, flags: ["k": .boolean(rollout: 0)])

        for _ in 0..<3 {
            _ = plugin.reduce(state: &state, action: .featureFlags(.setLocalOverride(key: "k", value: .bool(true))))
            try await record(.recordExposure(of: BoolFlag("k")), with: plugin, in: &state)
            _ = plugin.reduce(state: &state, action: .featureFlags(.clearLocalOverride(key: "k")))
            try await record(.recordExposure(of: BoolFlag("k")), with: plugin, in: &state)
        }

        #expect(log.all.map(\.value) == [.bool(true), .bool(false)])
    }

    @available(*, deprecated, message: "Exercises the deprecated key-only exposure.")
    @Test("the deprecated key-only exposure shares the value dedupe")
    func keyOnlyExposureSharesDedupe() async throws {
        let log = ExposureLog()
        let plugin = exposurePlugin(log)
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(version: 1, flags: ["k": .boolean(rollout: 100)])

        try await record(.recordExposure(key: "k"), with: plugin, in: &state)
        try await record(.recordExposure(of: BoolFlag("k")), with: plugin, in: &state)
        try await record(.recordExposure(key: "k"), with: plugin, in: &state)

        #expect(log.all.map(\.value) == [.bool(true)])
    }
}

/// Thread-safe exposure recorder; `onExposure` runs inside the effect.
final class ExposureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(key: String, value: FlagValue)] = []

    var all: [(key: String, value: FlagValue)] { lock.withLock { records } }

    func append(_ key: String, _ value: FlagValue) {
        lock.withLock { records.append((key, value)) }
    }
}

// MARK: - Helpers

@MainActor
final class ExposureCounter {
    private(set) var count = 0
    private(set) var records: [(String, FlagValue)] = []
    func record(key: String, value: FlagValue) {
        count += 1
        records.append((key, value))
    }
}
