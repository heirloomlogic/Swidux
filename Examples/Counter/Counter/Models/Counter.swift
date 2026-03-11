import Foundation

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
