import SwiftUI
import os

@Observable
final class AppStore: SwiduxDispatcher {
    // MARK: - Entity Stores

    private(set) var counters = EntityStore<Counter>()

    // MARK: - Ephemeral State

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
