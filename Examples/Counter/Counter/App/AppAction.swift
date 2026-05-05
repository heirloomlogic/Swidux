import Foundation

/// Root action type. Every user interaction and effect callback is expressed as an `AppAction`.
enum AppAction: Sendable {
    /// Counter feature actions (CRUD, increment/decrement).
    case counter(CounterAction)

    /// Set or clear the selected counter for row highlighting.
    case selectCounter(UUID?)
}

/// Actions handled by ``CounterReducer``.
enum CounterAction: Sendable {
    /// Create a new counter with a default name.
    case add

    /// Delete a counter by ID.
    case remove(UUID)

    /// Increment a counter's value by 1.
    case increment(UUID)

    /// Decrement a counter's value by 1 (floors at 0).
    case decrement(UUID)

    /// Increment after a 1-second delay. Demonstrates the async effect system.
    case incrementAsync(UUID)

    /// Rename a counter. Used by the controlled `TextField` binding.
    case setName(UUID, String)
}
