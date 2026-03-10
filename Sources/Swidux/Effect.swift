//
//  Effect.swift
//  Swidux
//
//  The async effect system.
//

/// A function for dispatching actions back to the store from within an effect.
public typealias Send<Action> = @MainActor @Sendable (Action) -> Void

/// An async unit of work returned by a reducer.
///
/// Effects receive a `send` function to dispatch follow-up actions.
/// Run effects with `Task { @concurrent in }` to keep them off the
/// MainActor.
///
/// ```swift
/// // In a reducer:
/// return { send in
///     let result = try await db.fetchAll()
///     await send(.dataLoaded(result))
/// }
/// ```
public typealias Effect<Action> = @Sendable (@escaping Send<Action>) async -> Void
