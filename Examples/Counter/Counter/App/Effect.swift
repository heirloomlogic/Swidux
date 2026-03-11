import Foundation

/// Concrete typealiases specializing Swidux's generic effect system for this app.
///
/// - `Send` is `@MainActor @Sendable (AppAction) -> Void` — dispatches hop back to MainActor.
/// - `Effect` is a `@Sendable` async closure — run with `Task { @concurrent in }`.
typealias Send = Swidux.Send<AppAction>
typealias Effect = Swidux.Effect<AppAction>
