import Testing

@testable import Counter

@MainActor
@Suite("CounterReducer")
struct CounterReducerTests {
    let reducer = CounterReducer()
    let env = AppEnvironment.mock()

    // MARK: - Pure State Mutations

    @Test("add inserts a new counter into the EntityStore")
    func add() {
        var state = AppState()
        _ = reducer.reduce(state: &state, action: .add, environment: env)

        #expect(state.counters.count == 1)
        #expect(state.counters.values.first?.count == 0)
        #expect(state.counters.values.first?.name == "Counter 1")
    }

    @Test("add generates sequential names")
    func addSequentialNames() {
        var state = AppState()
        _ = reducer.reduce(state: &state, action: .add, environment: env)
        _ = reducer.reduce(state: &state, action: .add, environment: env)

        let names = state.counters.values.map(\.name)
        #expect(names == ["Counter 1", "Counter 2"])
    }

    @Test("remove deletes the counter from the EntityStore")
    func remove() {
        var state = AppState()
        let counter = Counter(name: "Doomed")
        state.counters[counter.id] = counter

        _ = reducer.reduce(state: &state, action: .remove(counter.id), environment: env)

        #expect(state.counters.isEmpty)
    }

    @Test("increment adds 1 to the counter's count")
    func increment() {
        var state = AppState()
        let counter = Counter(name: "Test", count: 5)
        state.counters[counter.id] = counter

        _ = reducer.reduce(state: &state, action: .increment(counter.id), environment: env)

        #expect(state.counters[counter.id]?.count == 6)
    }

    @Test("decrement subtracts 1 but floors at zero")
    func decrement() {
        var state = AppState()
        let counter = Counter(name: "Test", count: 0)
        state.counters[counter.id] = counter

        _ = reducer.reduce(state: &state, action: .decrement(counter.id), environment: env)

        #expect(state.counters[counter.id]?.count == 0)
    }

    @Test("setName updates the counter name via modify")
    func setName() {
        var state = AppState()
        let counter = Counter(name: "Old")
        state.counters[counter.id] = counter

        _ = reducer.reduce(state: &state, action: .setName(counter.id, "New"), environment: env)

        #expect(state.counters[counter.id]?.name == "New")
    }

    // MARK: - Effect Returns

    @Test("synchronous actions return nil effect")
    func syncActionsReturnNil() {
        var state = AppState()
        let counter = Counter()
        state.counters[counter.id] = counter

        #expect(reducer.reduce(state: &state, action: .add, environment: env) == nil)
        #expect(reducer.reduce(state: &state, action: .increment(counter.id), environment: env) == nil)
        #expect(reducer.reduce(state: &state, action: .decrement(counter.id), environment: env) == nil)
        #expect(reducer.reduce(state: &state, action: .setName(counter.id, "X"), environment: env) == nil)
        #expect(reducer.reduce(state: &state, action: .remove(counter.id), environment: env) == nil)
    }

    @Test("incrementAsync returns a non-nil effect")
    func incrementAsyncReturnsEffect() {
        var state = AppState()
        let counter = Counter()
        state.counters[counter.id] = counter

        let effect = reducer.reduce(state: &state, action: .incrementAsync(counter.id), environment: env)

        #expect(effect != nil)
    }

    // MARK: - Effect Execution

    @Test("incrementAsync effect dispatches .counter(.increment) after delay")
    func incrementAsyncDispatchesIncrement() async {
        var state = AppState()
        let counter = Counter()
        state.counters[counter.id] = counter

        let effect = reducer.reduce(state: &state, action: .incrementAsync(counter.id), environment: env)!

        // Execute the effect with a capturing send function
        var dispatched: [AppAction] = []
        await effect { action in
            dispatched.append(action)
        }

        #expect(dispatched.count == 1)
        if case .counter(.increment(let id)) = dispatched.first {
            #expect(id == counter.id)
        } else {
            Issue.record("Expected .counter(.increment), got \(String(describing: dispatched.first))")
        }
    }
}
