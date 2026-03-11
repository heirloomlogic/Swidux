import Foundation
@_exported import Swidux

nonisolated struct AppState: Sendable, Equatable {
    var counters = EntityStore<Counter>()
}
