import SwiftUI
import os

@Observable
final class AppStore: SwiduxDispatcher {
    // MARK: - Entity Stores (persisted via middleware)

    private(set) var counters = EntityStore<Counter>()

    // MARK: - Dependencies

    private let environment: AppEnvironment
    private let reducer: AppReducer
    private let persistence: PersistenceMiddleware<AppState>

    private let logger: Logger

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
        self.logger = logger

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
        var state = AppState(counters: counters)

        let effect = reducer.reduce(
            state: &state,
            action: action,
            environment: environment
        )

        persistence.afterReduce(state: &state)

        // Guard @Observable writes with equality checks (Rule #9).
        // Without this, every send() triggers change notifications
        // even when the value is identical, causing cascading re-renders.
        if counters != state.counters { counters = state.counters }

        // Run effects off MainActor. A bare Task { } inherits MainActor
        // isolation here, keeping the entire effect on the main thread.
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
