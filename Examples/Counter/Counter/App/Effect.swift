import Foundation

/// Concrete typealiases specializing Swidux's generic effect system for this app.
///
/// - `Send` is `@MainActor @Sendable (AppAction) -> Void` — dispatches hop back to MainActor.
/// - `Effect` holds async work and cancellation metadata; construct it with `Effect { send in ... }`.
typealias Send = Swidux.Send<AppAction>
typealias Effect = Swidux.Effect<AppAction>
