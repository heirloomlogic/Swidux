import Foundation
@_exported import Swidux

@SwiduxState
nonisolated struct AppState: Equatable, Sendable {
    var counters: EntityStore<Counter> = .init()
    @SwiduxNested var ui: UIState = .init()

    init(counters: EntityStore<Counter> = EntityStore(), ui: UIState = UIState()) {
        self.counters = counters
        self.ui = ui
    }
}

@SwiduxState
nonisolated struct UIState: Equatable, Sendable {
    var selectedCounterID: UUID? = nil
}
