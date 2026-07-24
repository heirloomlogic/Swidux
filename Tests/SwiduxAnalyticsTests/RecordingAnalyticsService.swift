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

    /// Call from the plugin's `onConsentChange` hook so consent invocations
    /// interleave into ``log`` alongside the service calls.
    func consentChanged(to optedOut: Bool) {
        log.append("consent(\(optedOut))")
    }

    func track(_ event: AnalyticsEvent) async {
        trackedEvents.append(event)
        log.append("track")
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
