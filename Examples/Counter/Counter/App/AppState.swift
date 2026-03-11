import Foundation
@_exported import Swidux

nonisolated struct AppState: Sendable, Equatable {
    var counters = EntityStore<Counter>()
    var ui = UIState()
}

nonisolated struct UIState: Sendable, Equatable {
    var selectedCounterID: UUID?
}
