import Foundation

struct AppReducer: SwiduxReducer {
    let counter = CounterReducer()

    func reduce(
        state: inout AppState,
        action: AppAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {
        case .counter(let action):
            counter.reduce(state: &state, action: action, environment: environment)
        }
    }
}
