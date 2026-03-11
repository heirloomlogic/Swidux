import Foundation

/// Root reducer that routes actions to feature reducers.
///
/// Conforms to `SwiduxReducer` with `Action == AppAction` (root reducer).
/// Cases that don't need async work fall through to `return nil`.
struct AppReducer: SwiduxReducer {
    let counter = CounterReducer()

    func reduce(
        state: inout AppState,
        action: AppAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {
        case .counter(let action):
            return counter.reduce(state: &state, action: action, environment: environment)

        case .selectCounter(let id):
            state.ui.selectedCounterID = id
        }

        return nil
    }
}
