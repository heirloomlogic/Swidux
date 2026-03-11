import Foundation

/// Dependencies injected into reducers.
///
/// In a production app this would hold DB actors, API clients, and other services.
/// The Counter demo has no external dependencies, so this is a placeholder that
/// demonstrates the pattern.
struct AppEnvironment: Sendable {
    /// Production dependencies.
    static func live() -> AppEnvironment { .init() }

    /// Test/preview dependencies.
    static func mock() -> AppEnvironment { .init() }
}
