import Foundation

/// A named counter with an integer value.
///
/// This is the domain model managed by `EntityStore<Counter>`.
/// It conforms to `Identifiable`, `Equatable`, and `Sendable` as
/// required by `EntityStore`.
nonisolated struct Counter: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var count: Int

    init(id: UUID = UUID(), name: String = "Counter", count: Int = 0) {
        self.id = id
        self.name = name
        self.count = count
    }
}
