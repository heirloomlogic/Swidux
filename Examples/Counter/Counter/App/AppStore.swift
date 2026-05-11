import SwiduxFeatureFlags
import SwiftUI
import os

typealias AppStore = Store<AppState, AppAction>

extension Store where State == AppState, Action == AppAction {
    static func configured(environment: AppEnvironment = .live()) -> AppStore {
        let reducer = AppReducer()
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "counter",
            category: "persistence"
        )

        let isUndoable: @Sendable (AppAction) -> Bool = { action in
            switch action {
            case .counter(.add), .counter(.remove),
                .counter(.increment), .counter(.decrement),
                .counter(.setName):
                true
            case .counter(.incrementAsync), .selectCounter, .featureFlags:
                false
            }
        }

        let undoPlugin = UndoPlugin<AppState, AppAction>(
            isUndoable: isUndoable,
            coalescing: { action in
                if case .counter(.setName) = action { return true }
                return false
            }
        )

        let persistencePlugin = PersistencePlugin<AppState, AppAction>(
            writers: [
                StateWriter(keyPath: \.counters) { writes, deletes in
                    for counter in writes {
                        logger.info("Persist upsert: \(counter.name) = \(counter.count)")
                    }
                    for id in deletes {
                        logger.info("Persist delete: \(id)")
                    }
                }
            ],
            logger: logger
        )

        let keyValueStore = InMemoryKeyValueStore()
        let featureFlagsPlugin = FeatureFlagsPlugin<AppState, AppAction>(
            state: \.featureFlags,
            action: AppAction.featureFlags,
            extractAction: {
                if case .featureFlags(let a) = $0 { return a }
                return nil
            },
            service: BundledFeatureFlagsService(),
            refreshPolicy: .manual,
            keyValueStore: keyValueStore
        )

        let plugins = PluginHost<AppState, AppAction>()
        plugins.register(undoPlugin)
        plugins.register(persistencePlugin)
        plugins.register(featureFlagsPlugin)

        return Store(
            initialState: AppState(),
            reducer: { state, action in
                reducer.reduce(state: &state, action: action, environment: environment)
            },
            plugins: plugins,
            undoPlugin: undoPlugin,
            persistencePlugin: persistencePlugin,
            isUndoable: isUndoable
        )
    }
}
