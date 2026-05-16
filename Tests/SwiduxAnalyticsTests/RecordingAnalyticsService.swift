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

    func track(_ event: AnalyticsEvent) async {
        trackedEvents.append(event)
    }

    func identify(userID: String, properties: [String: AnalyticsValue]) async {
        identifyCalls.append(IdentifyCall(userID: userID, properties: properties))
    }

    func alias(newID: String, previousID: String?) async {
        aliasCalls.append(AliasCall(newID: newID, previousID: previousID))
    }

    func reset() async {
        resetCount += 1
    }

    func flush() async {
        flushCount += 1
    }
}
