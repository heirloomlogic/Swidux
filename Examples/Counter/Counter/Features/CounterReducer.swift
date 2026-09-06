import Foundation
import SwiduxFeatureFlags

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
            // Honour the `max_counters` feature flag — drop the add when at the
            // cap. The UI also disables the + button at the limit, so this is a
            // belt-and-braces guard (a stray dispatch from a hotkey, an effect,
            // etc. still can't exceed the cap).
            let cap = state.featureFlags.value(of: .maxCounters)
            guard state.counters.count < cap else { break }
            let counter = Counter(name: "Counter \(state.counters.count + 1)")
            state.counters[counter.id] = counter

        case .remove(let id):
            state.counters[id] = nil

        case .increment(let id):
            state.counters.modify(id) { $0.count += 1 }

        case .decrement(let id):
            state.counters.modify(id) { $0.count = max(0, $0.count - 1) }

        case .incrementAsync(let id):
            // Capture the user-tunable delay by value: the slider position at
            // dispatch time is what this in-flight effect uses, even if the
            // slider moves before the effect completes.
            let delay = state.ui.asyncDelay
            return Effect { send in
                try? await Task.sleep(for: .seconds(delay))
                await send(.counter(.increment(id)))
            }

        case .setName(let id, let name):
            state.counters.modify(id) { $0.name = name }
        }

        return nil
    }
}
