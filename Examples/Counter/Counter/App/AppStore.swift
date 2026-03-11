import SwiftUI
import os

/// The observable store that owns app state and dispatches actions.
///
/// Each state slice is a separate stored property so that `@Observable` tracks
/// dependencies at the property level — a view reading `counters` won't
/// re-render when only `ui` changes (cross-slice isolation).
///
/// `send()` uses the **snapshot pattern**: it packs properties into a local
/// `AppState` value, mutates the copy via the reducer, then assigns back.
/// The final assignments route through the `set` accessor, which lets
/// `@Observable` check `Equatable` and suppress no-op notifications.
@Observable
final class AppStore: SwiduxDispatcher {
    // MARK: - Entity Stores

    /// All counters. Change-tracked by `PersistenceMiddleware`.
    private(set) var counters = EntityStore<Counter>()

    // MARK: - Ephemeral State

    /// UI-only state (selection, flags). Not persisted.
    private(set) var ui = UIState()

    // MARK: - Dependencies

    private let environment: AppEnvironment
    private let reducer: AppReducer
    private let persistence: PersistenceMiddleware<AppState>

    // MARK: - Init

    init(
        environment: AppEnvironment = .live(),
        reducer: AppReducer = AppReducer()
    ) {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "counter",
            category: "persistence"
        )

        self.environment = environment
        self.reducer = reducer

        // In a production app, writers call DB actors (e.g. counterDB.upsert).
        // This demo just logs to the console.
        self.persistence = PersistenceMiddleware(
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
    }

    // MARK: - Dispatch

    /// Dispatch an action through the reducer and persistence middleware.
    ///
    /// Uses the snapshot pattern to preserve `@Observable` equality checking:
    /// 1. Pack stored properties into a local `AppState` value.
    /// 2. Mutate the copy via the reducer (inout on a local — no observation).
    /// 3. Drain changelogs via the persistence middleware.
    /// 4. Assign back — `set` accessor checks equality, suppressing no-op notifications.
    /// 5. Run any returned effect off the MainActor.
    func send(_ action: AppAction) {
        var state = AppState(counters: counters, ui: ui)

        let effect = reducer.reduce(
            state: &state,
            action: action,
            environment: environment
        )

        persistence.afterReduce(state: &state)

        counters = state.counters
        ui = state.ui

        if let effect {
            let send: Send = { [weak self] action in
                self?.send(action)
            }
            Task { @concurrent in
                await effect(send)
            }
        }
    }
}
