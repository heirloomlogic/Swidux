//
//  RecordingAnalyticsService.swift
//  SwiduxAnalytics
//

import os

/// Analytics service that records every call it receives, for SwiftUI
/// previews and Swift Testing suites.
///
/// Tests written against the recorder don't depend on the analytics vendor,
/// so they stay the same when the app changes provider. Await the plugin's
/// `flush()` before reading, so every queued call has arrived:
///
/// ```swift
/// let recorder = RecordingAnalyticsService()
/// let store = AppStore.configured(
///     analyticsService: recorder,
///     onConsentChange: { await recorder.setOptedOut($0) }
/// )
///
/// store.send(.analytics(.setOptedOut(true)))
/// await store.analyticsPlugin.flush()
///
/// #expect(await recorder.calls == [.setOptedOut(true), .reset, .flush])
/// ```
///
/// ``calls`` holds every call in the order it arrived, which is what an
/// assertion about sequencing needs, such as the consent hook running before
/// the opt-out's `reset`. ``trackedEvents``, ``identifyCalls``,
/// ``aliasCalls``, ``resetCount``, and ``flushCount`` read one kind of call
/// from that log.
///
/// The recorder keeps everything, including calls a real service would
/// drop, such as tracking while opted out. Assert consent through the
/// ``Call/setOptedOut(_:)`` entries, not the absence of events.
///
/// > Warning: The log grows without limit, so this is not a production
/// > service. It emits a fault at init in Release builds, as
/// > ``ConsoleAnalyticsService`` does.
public actor RecordingAnalyticsService: AnalyticsService {
    /// One recorded call.
    public enum Call: Sendable, Equatable {
        /// `track(_:)` with its event.
        case track(AnalyticsEvent)
        /// `identify(userID:properties:)` with its arguments.
        case identify(userID: String, properties: [String: AnalyticsValue])
        /// `alias(newID:previousID:)` with its arguments.
        case alias(newID: String, previousID: String?)
        /// `reset()`.
        case reset
        /// `flush()`.
        case flush
        /// ``RecordingAnalyticsService/setOptedOut(_:)``, the consent hook.
        case setOptedOut(Bool)
    }

    /// The arguments of one `identify(userID:properties:)` call.
    public struct IdentifyCall: Sendable, Equatable {
        /// The user ID passed to `identify`.
        public let userID: String
        /// The people properties passed to `identify`.
        public let properties: [String: AnalyticsValue]

        /// Creates a record, e.g. as the expected value in an assertion.
        public init(userID: String, properties: [String: AnalyticsValue] = [:]) {
            self.userID = userID
            self.properties = properties
        }
    }

    /// The arguments of one `alias(newID:previousID:)` call.
    public struct AliasCall: Sendable, Equatable {
        /// The new ID passed to `alias`.
        public let newID: String
        /// The previous ID passed to `alias`, or `nil`.
        public let previousID: String?

        /// Creates a record, e.g. as the expected value in an assertion.
        public init(newID: String, previousID: String? = nil) {
            self.newID = newID
            self.previousID = previousID
        }
    }

    /// Every call received, in arrival order.
    public private(set) var calls: [Call] = []

    /// The event of every `track(_:)` call, in arrival order.
    public var trackedEvents: [AnalyticsEvent] {
        calls.compactMap {
            if case .track(let event) = $0 { event } else { nil }
        }
    }

    /// Every `identify(userID:properties:)` call, in arrival order.
    public var identifyCalls: [IdentifyCall] {
        calls.compactMap {
            if case .identify(let userID, let properties) = $0 {
                IdentifyCall(userID: userID, properties: properties)
            } else {
                nil
            }
        }
    }

    /// Every `alias(newID:previousID:)` call, in arrival order.
    public var aliasCalls: [AliasCall] {
        calls.compactMap {
            if case .alias(let newID, let previousID) = $0 {
                AliasCall(newID: newID, previousID: previousID)
            } else {
                nil
            }
        }
    }

    /// The number of `reset()` calls.
    public var resetCount: Int {
        calls.count(where: { $0 == .reset })
    }

    /// The number of `flush()` calls.
    public var flushCount: Int {
        calls.count(where: { $0 == .flush })
    }

    /// Creates an empty recorder.
    public init() {
        #if !DEBUG
        Logger(subsystem: "Swidux", category: "Analytics").fault(
            """
            RecordingAnalyticsService active in a Release build. It keeps every \
            analytics call in memory and sends nothing. Replace it with a real \
            AnalyticsService before App Store submission.
            """
        )
        #endif
    }

    /// Records the call.
    public func track(_ event: AnalyticsEvent) async {
        calls.append(.track(event))
    }

    /// Records the call.
    public func identify(userID: String, properties: [String: AnalyticsValue]) async {
        calls.append(.identify(userID: userID, properties: properties))
    }

    /// Records the call.
    public func alias(newID: String, previousID: String?) async {
        calls.append(.alias(newID: newID, previousID: previousID))
    }

    /// Records the call.
    public func reset() async {
        calls.append(.reset)
    }

    /// Records the call.
    public func flush() async {
        calls.append(.flush)
    }

    /// Records a consent change. Call it from the plugin's `onConsentChange`
    /// hook so consent appears in ``calls`` alongside the service calls.
    public func setOptedOut(_ optedOut: Bool) async {
        calls.append(.setOptedOut(optedOut))
    }
}
