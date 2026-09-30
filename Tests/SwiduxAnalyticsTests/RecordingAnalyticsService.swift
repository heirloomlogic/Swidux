//
//  RecordingAnalyticsService.swift
//  SwiduxAnalyticsTests
//
//  Shared recording mock for the analytics test suites.
//

import Swidux

@testable import SwiduxAnalytics

actor RecordingAnalyticsService: AnalyticsService {
    struct IdentifyCall: Equatable {
        let userID: String
        let properties: [String: AnalyticsValue]
    }
    struct AliasCall: Equatable {
        let newID: String
        let previousID: String?
    }

    private(set) var trackedEvents: [AnalyticsEvent] = []
    private(set) var identifyCalls: [IdentifyCall] = []
    private(set) var aliasCalls: [AliasCall] = []
    private(set) var resetCount: Int = 0
    private(set) var flushCount: Int = 0

    /// Every call in arrival order, for tests that care about sequencing
    /// across call kinds — the per-kind collections above can't express it.
    private(set) var log: [String] = []

    private let stallsTracks: Bool
    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private let trackParked = AsyncStream<Void>.makeStream()

    /// With `stallTracks`, every `track` records itself and then parks until
    /// ``release()``, so the plugin's queue backs up behind the first one.
    init(stallTracks: Bool = false) {
        stallsTracks = stallTracks
    }

    /// Call from the plugin's `onConsentChange` hook so consent invocations
    /// interleave into ``log`` alongside the service calls.
    func consentChanged(to optedOut: Bool) {
        log.append("consent(\(optedOut))")
    }

    /// Lets every parked and future `track` call return.
    func release() {
        released = true
        for continuation in parked {
            continuation.resume()
        }
        parked.removeAll()
    }

    /// Suspends until a `track` call has parked.
    func trackStarted() async {
        for await _ in trackParked.stream { break }
    }

    func track(_ event: AnalyticsEvent) async {
        trackedEvents.append(event)
        log.append("track")
        guard stallsTracks, !released else { return }
        trackParked.continuation.yield()
        await withCheckedContinuation { parked.append($0) }
    }

    func identify(userID: String, properties: [String: AnalyticsValue]) async {
        identifyCalls.append(IdentifyCall(userID: userID, properties: properties))
        log.append("identify")
    }

    func alias(newID: String, previousID: String?) async {
        aliasCalls.append(AliasCall(newID: newID, previousID: previousID))
        log.append("alias")
    }

    func reset() async {
        resetCount += 1
        log.append("reset")
    }

    func flush() async {
        flushCount += 1
        log.append("flush")
    }
}

/// A service whose calls never return, for exercising flush timeouts.
actor HangingAnalyticsService: AnalyticsService {
    private func hang() async {
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    func track(_ event: AnalyticsEvent) async { await hang() }
    func identify(userID: String, properties: [String: AnalyticsValue]) async { await hang() }
    func alias(newID: String, previousID: String?) async { await hang() }
    func reset() async { await hang() }
    func flush() async { await hang() }
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
@MainActor
func poll(until condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
    var waited = Duration.zero
    while !condition(), waited < timeout {
        try await Task.sleep(for: .milliseconds(5))
        waited += .milliseconds(5)
    }
}
