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

    // MARK: - Undo State

    /// Whether there is a state to undo to.
    private(set) var canUndo = false

    /// Whether there is a state to redo to.
    private(set) var canRedo = false

    // MARK: - Dependencies

    private let environment: AppEnvironment
    private let reducer: AppReducer
    private let persistence: PersistenceMiddleware<AppState>
    private let undoMiddleware = UndoMiddleware<AppState>()

    /// System UndoManager bridge for iOS shake-to-undo.
    /// Set from the view layer via `@Environment(\.undoManager)`.
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
    /// 1. Snapshot current state for undo (if undoable).
    /// 2. Pack stored properties into a local `AppState` value.
    /// 3. Mutate the copy via the reducer (inout on a local — no observation).
    /// 4. Drain changelogs via the persistence middleware.
    /// 5. Assign back — `set` accessor checks equality, suppressing no-op notifications.
    /// 6. Run any returned effect off the MainActor.
    func send(_ action: AppAction) {
        let current = AppState(counters: counters, ui: ui)

        if action.isUndoable {
            undoMiddleware.willReduce(state: current, coalescing: action.isCoalescing)
        }

        var state = current

        let effect = reducer.reduce(
            state: &state,
            action: action,
            environment: environment
        )

        persistence.afterReduce(state: &state)

        counters = state.counters
        ui = state.ui
        syncUndoState()

        if action.isUndoable {
            undoManager?.registerUndo(withTarget: self) { $0.undo() }
        }

        if let effect {
            let send: Send = { [weak self] action in
                self?.send(action)
            }
            Task { @concurrent in
                await effect(send)
            }
        }
    }

    // MARK: - Undo / Redo

    /// Restores the previous state. No-op if nothing to undo.
    func undo() {
        let current = AppState(counters: counters, ui: ui)
        guard let restored = undoMiddleware.undo(current: current) else { return }
        applySnapshot(restored)
        // Register redo with system (registerUndo during undo becomes redo)
        undoManager?.registerUndo(withTarget: self) { $0.redo() }
    }

    /// Re-applies a previously undone state. No-op if nothing to redo.
    func redo() {
        let current = AppState(counters: counters, ui: ui)
        guard let restored = undoMiddleware.redo(current: current) else { return }
        applySnapshot(restored)
        // Register undo with system (registerUndo during redo becomes undo)
        undoManager?.registerUndo(withTarget: self) { $0.undo() }
    }

    /// Restores a snapshot, recording diffs for persistence.
    private func applySnapshot(_ restored: AppState) {
        var state = AppState(counters: counters, ui: ui)
        state.counters.restore(from: restored.counters)
        state.ui = restored.ui

        persistence.afterReduce(state: &state)

        counters = state.counters
        ui = state.ui
        syncUndoState()
    }

    private func syncUndoState() {
        canUndo = undoMiddleware.canUndo
        canRedo = undoMiddleware.canRedo
    }
}
