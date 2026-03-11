import Foundation

struct AppEnvironment: Sendable {
    static func live() -> AppEnvironment { .init() }
    static func mock() -> AppEnvironment { .init() }
}
