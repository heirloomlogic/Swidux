import Foundation
import Swidux

/// Hand-written observer class tree for AppState.
///
/// In Phase 2, the `@SwiduxState` macro generates this automatically.
///
/// `@Observable` fires notifications only when a stored property's value
/// actually changes (equality-checked on `set`). Nested observers use `let`
/// so that accessing `store.ui.selectedCounterID` tracks only
/// `selectedCounterID` on UIStateObserver — not `ui` on AppStateObserver.
@Observable
@MainActor
final class AppStateObserver {
    var counters: EntityStore<Counter>
    let ui: UIStateObserver

    init(counters: EntityStore<Counter> = EntityStore(), ui: UIStateObserver = UIStateObserver()) {
        self.counters = counters
        self.ui = ui
    }
}

@Observable
@MainActor
final class UIStateObserver {
    var selectedCounterID: UUID?

    init(selectedCounterID: UUID? = nil) {
        self.selectedCounterID = selectedCounterID
    }
}
