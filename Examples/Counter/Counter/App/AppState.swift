import Foundation
@_exported import Swidux

/// Root state for the app, composed of persisted entity stores and ephemeral UI state.
///
/// `AppState` is a value type used as a snapshot inside `AppStore.send()`.
/// The snapshot pattern (copy out → mutate → assign back) lets `@Observable`
/// check equality on each stored property and suppress redundant notifications.
nonisolated struct AppState: Sendable, Equatable {
    /// All counters, keyed by ID with insertion-order iteration.
    var counters = EntityStore<Counter>()

    /// Ephemeral UI state that is not persisted.
    var ui = UIState()
}

/// Non-persisted UI state.
nonisolated struct UIState: Sendable, Equatable {
    /// The currently selected counter, if any. Used for row highlighting.
    var selectedCounterID: UUID?
}
