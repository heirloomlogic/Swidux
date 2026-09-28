//
//  UndoRestoreTests.swift
//  SwiduxFeatureFlagsTests
//
//  Undo must never roll the flags slice back. `isFetching` is cleared only by
//  the refresh effect's completion; restoring it from a snapshot taken while a
//  fetch was in flight latches it with nothing left to clear it, and every
//  later `.refresh` is refused for the rest of the session.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxFeatureFlags

@Swidux
nonisolated struct FlagsUndoRoot: Equatable, Sendable {
    @Slice var featureFlags: FeatureFlagsState = .init()
    var deviceID: String = "device"
    var document: Int = 0
}

enum FlagsUndoAction: Sendable {
    case featureFlags(FeatureFlagsAction)
    case edit
}

@Suite("FeatureFlags under undo")
@MainActor
struct FeatureFlagsUndoRestoreTests {
    @Test("Undo does not latch an in-flight refresh")
    func undoDoesNotLatchIsFetching() async throws {
        let service = MockFeatureFlagsService(outcome: .success(.empty))
        let isUndoable: @Sendable (FlagsUndoAction) -> Bool = { if case .edit = $0 { true } else { false } }
        let undo = UndoPlugin<FlagsUndoRoot, FlagsUndoAction>(isUndoable: isUndoable)
        let plugins = PluginHost<FlagsUndoRoot, FlagsUndoAction>()
        plugins.register(undo)
        plugins.register(
            FeatureFlagsPlugin<FlagsUndoRoot, FlagsUndoAction>(
                state: \.featureFlags,
                action: FlagsUndoAction.featureFlags,
                extractAction: { if case .featureFlags(let a) = $0 { a } else { nil } },
                service: service,
                deviceIDKeyPath: \.deviceID,
                refreshPolicy: .manual,
                keyValueStore: InMemoryKeyValueStore()
            ))
        let store = Store(
            initialState: FlagsUndoRoot(),
            reducer: { state, action in
                if case .edit = action { state.document += 1 }
                return nil
            },
            plugins: plugins,
            undoPlugin: undo
        )
        defer { store.cancelEffects() }

        store.send(.featureFlags(.refresh))
        // Dispatched before the fetch effect can run, so the snapshot this edit
        // takes has `isFetching == true`.
        store.send(.edit)
        try await poll(until: { !store.featureFlags.isFetching })
        #expect(!store.featureFlags.isFetching)

        store.undo()

        #expect(store.document == 0, "the app's own edit is still undone")
        #expect(!store.featureFlags.isFetching, "undo latched isFetching")
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
@MainActor
private func poll(until condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
    var waited = Duration.zero
    while !condition(), waited < timeout {
        try await Task.sleep(for: .milliseconds(5))
        waited += .milliseconds(5)
    }
}
