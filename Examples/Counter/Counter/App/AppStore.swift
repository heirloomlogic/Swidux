import SwiftUI
import os

@Observable
final class AppStore: SwiduxDispatcher {
    // MARK: - Entity Stores

    private(set) var counters = EntityStore<Counter>()

    // MARK: - Ephemeral State

    private(set) var ui = UIState()

    // MARK: - Undo State

    private(set) var canUndo = false
    private(set) var canRedo = false

    // MARK: - Dependencies

    private let environment: AppEnvironment
    private let reducer: AppReducer
    private let plugins: PluginHost<AppState, AppAction>
    private let undoPlugin: UndoPlugin<AppState, AppAction>
    private let persistencePlugin: PersistencePlugin<AppState, AppAction>
    private let isUndoable: @Sendable (AppAction) -> Bool

    weak var undoManager: UndoManager?

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

        let isUndoable: @Sendable (AppAction) -> Bool = { action in
            switch action {
            case .counter(.add), .counter(.remove),
                .counter(.increment), .counter(.decrement),
                .counter(.setName):
                true
            case .counter(.incrementAsync), .selectCounter:
                false
            }
        }
        self.isUndoable = isUndoable

        self.undoPlugin = UndoPlugin(
            isUndoable: isUndoable,
            coalescing: { action in
                if case .counter(.setName) = action { return true }
                return false
            }
        )

        self.persistencePlugin = PersistencePlugin(
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

        self.plugins = PluginHost()
        plugins.register(undoPlugin)
        plugins.register(persistencePlugin)
    }

    // MARK: - Dispatch

    func send(_ action: AppAction) {
        var state = AppState(counters: counters, ui: ui)

        plugins.willReduce(state: state, action: action)

        let effect = reducer.reduce(
            state: &state,
            action: action,
            environment: environment
        )

        let pluginEffects = plugins.reduce(state: &state, action: action)
        plugins.afterReduce(state: &state, action: action)

        counters = state.counters
        ui = state.ui
        syncUndoState()

        if isUndoable(action) {
            undoManager?.registerUndo(withTarget: self) { $0.undo() }
        }

        let send: Send = { [weak self] action in
            self?.send(action)
        }
        let allEffects = [effect].compactMap { $0 } + pluginEffects
        for eff in allEffects {
            Task { @concurrent in
                await eff(send)
            }
        }
    }

    // MARK: - Undo / Redo

    func undo() {
        let current = AppState(counters: counters, ui: ui)
        guard let restored = undoPlugin.undo(current: current) else { return }
        applySnapshot(restored)
        undoManager?.registerUndo(withTarget: self) { $0.redo() }
    }

    func redo() {
        let current = AppState(counters: counters, ui: ui)
        guard let restored = undoPlugin.redo(current: current) else { return }
        applySnapshot(restored)
        undoManager?.registerUndo(withTarget: self) { $0.undo() }
    }

    private func applySnapshot(_ restored: AppState) {
        var state = AppState(counters: counters, ui: ui)
        state.counters.restore(from: restored.counters)
        state.ui = restored.ui

        // Drain persistence directly — undo/redo bypasses the action dispatch path.
        // PersistencePlugin.afterReduce ignores the action value.
        persistencePlugin.afterReduce(state: &state, action: .selectCounter(nil))

        counters = state.counters
        ui = state.ui
        syncUndoState()
    }

    private func syncUndoState() {
        canUndo = undoPlugin.canUndo
        canRedo = undoPlugin.canRedo
    }
}
