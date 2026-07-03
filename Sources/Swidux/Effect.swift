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
/// The store runs each effect with `Task { @concurrent in }` to keep it off
/// the MainActor, retains the task until it finishes, and cancels all
/// in-flight effects when it deinitializes (or on `Store.cancelEffects()`).
///
/// Effects may throw: a thrown error is logged by the store, except
/// `CancellationError`, which is expected during teardown and ignored.
/// Non-throwing closures convert implicitly, so `return { send in … }`
/// works unchanged either way.
///
/// ```swift
/// // In a reducer:
/// return { send in
///     let result = try await db.fetchAll()
///     await send(.dataLoaded(result))
/// }
/// ```
public typealias Effect<Action> = @Sendable (@escaping Send<Action>) async throws -> Void
