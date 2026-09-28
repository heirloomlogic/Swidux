//
//  UndoRestoreTests.swift
//  SwiduxAnalyticsTests
//
//  Undo must never reverse a consent decision. Only `.setOptedOut` runs the
//  consent hook and invalidates queued work; restoring `isOptedOut` from a
//  snapshot taken before an unrelated edit would reopen the plugin's gate
//  behind the vendor SDK's back.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxAnalytics

@Swidux
nonisolated struct AnalyticsUndoRoot: Equatable, Sendable {
    @Slice var analytics: AnalyticsState = .init()
    var document: Int = 0
}

enum AnalyticsUndoAction: Sendable {
    case analytics(AnalyticsAction)
    case edit
    case tap
}

@Suite("Analytics under undo")
@MainActor
struct AnalyticsUndoRestoreTests {
    @Test("Undo does not reverse an opt-out")
    func undoKeepsOptOut() async {
        let service = RecordingAnalyticsService()
        let isUndoable: @Sendable (AnalyticsUndoAction) -> Bool = { if case .edit = $0 { true } else { false } }
        let undo = UndoPlugin<AnalyticsUndoRoot, AnalyticsUndoAction>(isUndoable: isUndoable)
        let analytics = AnalyticsPlugin<AnalyticsUndoRoot, AnalyticsUndoAction>(
            state: \.analytics,
            action: AnalyticsUndoAction.analytics,
            extractAction: { if case .analytics(let a) = $0 { a } else { nil } },
            service: service,
            mapper: AnalyticsMapper { _, action in
                if case .tap = action { [AnalyticsEvent("tap")] } else { [] }
            }
        )
        let plugins = PluginHost<AnalyticsUndoRoot, AnalyticsUndoAction>()
        plugins.register(undo)
        plugins.register(analytics)
        let store = Store(
            initialState: AnalyticsUndoRoot(),
            reducer: { state, action in
                if case .edit = action { state.document += 1 }
                return nil
            },
            plugins: plugins,
            undoPlugin: undo
        )
        defer { store.cancelEffects() }

        store.send(.edit)
        store.send(.analytics(.setOptedOut(true)))

        store.undo()
        store.send(.tap)
        await analytics.flush()

        #expect(store.document == 0, "the app's own edit is still undone")
        #expect(store.analytics.isOptedOut, "undo reversed the opt-out")
        #expect(await service.trackedEvents.isEmpty, "an event was tracked after opting out")
    }
}
