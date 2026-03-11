import Foundation

/// Handles all counter CRUD and mutation actions.
///
/// Conforms to `SwiduxReducer` with `Action = CounterAction`.
/// Most cases are synchronous state mutations that return `nil`.
/// `incrementAsync` demonstrates an effect that dispatches after a delay.
struct CounterReducer: SwiduxReducer {
    func reduce(
        state: inout AppState,
        action: CounterAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {
        case .add:
            let counter = Counter(name: "Counter \(state.counters.count + 1)")
            state.counters[counter.id] = counter

        case .remove(let id):
            state.counters[id] = nil

        case .increment(let id):
            state.counters.modify(id) { $0.count += 1 }

        case .decrement(let id):
            state.counters.modify(id) { $0.count = max(0, $0.count - 1) }

        case .incrementAsync(let id):
            // Return an effect — an async closure that runs off the MainActor.
            // After the delay, it dispatches a synchronous increment.
            return { send in
                try? await Task.sleep(for: .seconds(1))
                await send(.counter(.increment(id)))
            }

        case .setName(let id, let name):
            state.counters.modify(id) { $0.name = name }
        }

        return nil
    }
}
