//
//  Effect.swift
//  Swidux
//
//  The async effect system.
//  Apps create concrete versions: `typealias Effect = Swidux.Effect<AppAction>`
//

import Foundation

/// A function for dispatching actions back to the store from within an effect.
public typealias Send<Action> = @MainActor @Sendable (Action) -> Void

/// An async unit of work returned by a reducer.
///
/// Effects receive a `send` function to dispatch follow-up actions.
/// The closure body has `package` access — downstream apps cannot
/// execute effects directly. Use ``SwiduxDispatcher/runEffect(_:send:)``
/// to run effects on the cooperative thread pool.
///
/// ```swift
/// // In a reducer:
/// return Effect { send in
///     let result = try await db.fetchAll()
///     send(.dataLoaded(result))
/// }
/// ```
public struct Effect<Action>: Sendable {
    /// The effect body. `package` access ensures only Swidux's own
    /// `runEffect` can execute it — downstream apps must go through
    /// the framework's threading machinery.
    package let body: @Sendable (@escaping Send<Action>) async -> Void

    /// Creates an effect from an async closure.
    ///
    /// - Parameter body: The async work to perform. Use the provided
    ///   `send` function to dispatch follow-up actions.
    public init(_ body: @escaping @Sendable (@escaping Send<Action>) async -> Void) {
        self.body = body
    }
}
