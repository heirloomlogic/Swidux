import Foundation
@_exported import Swidux

/// Root state for the app, composed of persisted entity stores and ephemeral UI state.
///
/// Conforms to `SwiduxObservable` to bridge to the observer class tree.
/// The struct remains the canonical representation — reducers mutate it via `inout`.
nonisolated struct AppState: SwiduxObservable {
    var counters = EntityStore<Counter>()
    var ui = UIState()

    init(counters: EntityStore<Counter> = EntityStore(), ui: UIState = UIState()) {
        self.counters = counters
        self.ui = ui
    }

    // MARK: - SwiduxObservable

    typealias Observer = AppStateObserver

    @MainActor
    init(observer: AppStateObserver) {
        self.counters = observer.counters
        self.ui = UIState(observer: observer.ui)
    }

    @MainActor
    static func makeObserver(from state: AppState) -> AppStateObserver {
        AppStateObserver(
            counters: state.counters,
            ui: UIStateObserver(selectedCounterID: state.ui.selectedCounterID)
        )
    }

    @MainActor
    static func apply(_ snapshot: AppState, to observer: AppStateObserver) {
        observer.counters = snapshot.counters
        UIState.apply(snapshot.ui, to: observer.ui)
    }

    @MainActor
    static func applyRestore(from snapshot: AppState, to current: inout AppState) {
        current.counters.restore(from: snapshot.counters)
        current.ui = snapshot.ui
    }
}

/// Non-persisted UI state.
nonisolated struct UIState: Sendable, Equatable {
    var selectedCounterID: UUID?

    @MainActor
    init(observer: UIStateObserver) {
        self.selectedCounterID = observer.selectedCounterID
    }

    init(selectedCounterID: UUID? = nil) {
        self.selectedCounterID = selectedCounterID
    }

    @MainActor
    static func apply(_ snapshot: UIState, to observer: UIStateObserver) {
        observer.selectedCounterID = snapshot.selectedCounterID
    }
}
