import Foundation

enum AppAction: Sendable {
    case counter(CounterAction)
}

enum CounterAction: Sendable {
    case add
    case remove(UUID)
    case increment(UUID)
    case decrement(UUID)
    case incrementAsync(UUID)
    case setName(UUID, String)
}
