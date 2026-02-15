//
//  SwiduxReducer.swift
//  Swidux
//
//  Protocol defining the reducer contract.
//

import Foundation

/// A reducer that transforms state in response to actions.
///
/// Conforming types implement the core business logic of the application.
/// Reducers are synchronous — they mutate state and optionally return
/// an asynchronous `Effect` for side effects (network, analytics, etc.).
///
/// - `Action` is the action type this reducer handles (e.g. `CardEditorAction`).
/// - `RootAction` is the app-level action type used in effects (e.g. `AppAction`).
///   For root reducers, `Action` and `RootAction` are the same type.
///
/// ```swift
/// struct CounterReducer: SwiduxReducer {
///     func reduce(
///         state: inout AppState,
///         action: CounterAction,
///         environment: AppEnvironment
///     ) -> Effect<AppAction>? {
///         switch action {
///         case .increment(let id):
///             state.counters.modify(id) { $0.count += 1 }
///         }
///         return nil
///     }
/// }
/// ```
public protocol SwiduxReducer<State, Action, RootAction, Environment> {
    associatedtype State
    associatedtype Action
    associatedtype RootAction
    associatedtype Environment

    /// Synchronously mutates state in response to an action.
    ///
    /// Return an `Effect` for async work (DB calls, network, analytics),
    /// or `nil` when no side effects are needed. Effects dispatch follow-up
    /// actions using the `RootAction` type.
    func reduce(
        state: inout State,
        action: Action,
        environment: Environment
    ) -> Effect<RootAction>?
}
