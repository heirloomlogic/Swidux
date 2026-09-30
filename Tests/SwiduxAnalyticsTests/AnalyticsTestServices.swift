//
//  AnalyticsTestServices.swift
//  SwiduxAnalyticsTests
//
//  Test helpers built on the public RecordingAnalyticsService.
//

import Swidux

@testable import SwiduxAnalytics

extension RecordingAnalyticsService {
    /// ``calls`` as short labels (`"track"`, `"consent(true)"`), for
    /// sequencing assertions that don't care about arguments.
    var log: [String] {
        calls.map { call in
            switch call {
            case .track: "track"
            case .identify: "identify"
            case .alias: "alias"
            case .reset: "reset"
            case .flush: "flush"
            case .setOptedOut(let optedOut): "consent(\(optedOut))"
            }
        }
    }
}

/// Records through a ``RecordingAnalyticsService``, but every `track` parks
/// after recording until ``release()``, so the plugin's queue backs up
/// behind the first one.
actor StallingAnalyticsService: AnalyticsService {
    let recorder = RecordingAnalyticsService()

    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private let trackParked = AsyncStream<Void>.makeStream()

    var log: [String] {
        get async { await recorder.log }
    }

    var trackedEvents: [AnalyticsEvent] {
        get async { await recorder.trackedEvents }
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

    func setOptedOut(_ optedOut: Bool) async {
        await recorder.setOptedOut(optedOut)
    }

    func track(_ event: AnalyticsEvent) async {
        await recorder.track(event)
        guard !released else { return }
        trackParked.continuation.yield()
        await withCheckedContinuation { parked.append($0) }
    }

    func identify(userID: String, properties: [String: AnalyticsValue]) async {
        await recorder.identify(userID: userID, properties: properties)
    }

    func alias(newID: String, previousID: String?) async {
        await recorder.alias(newID: newID, previousID: previousID)
    }

    func reset() async {
        await recorder.reset()
    }

    func flush() async {
        await recorder.flush()
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
