//
//  Effect.swift
//  Swidux
//
//  Generic typealiases for the effect system.
//  Apps create concrete versions: `typealias Effect = Swidux.Effect<AppAction>`
//

import Foundation

/// A function for dispatching actions back to the store from within an effect.
public typealias Send<Action> = @MainActor (Action) -> Void

/// An async unit of work returned by a reducer.
///
/// Effects receive a `send` function to dispatch follow-up actions.
/// They are `@Sendable` to safely cross actor boundaries.
///
/// ```swift
/// // In a reducer:
/// return { send in
///     let result = try await db.fetchAll()
///     send(.dataLoaded(result))
/// }
/// ```
public typealias Effect<Action> = @Sendable (@escaping Send<Action>) async -> Void
