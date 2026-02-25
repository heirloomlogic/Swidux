//
//  SwiduxDispatcher.swift
//  Swidux
//
//  Protocol defining the store dispatch contract.
//

import Foundation

/// A type that can dispatch actions into the Swidux data flow.
///
/// Conforming types (typically your `AppStore`) provide the single
/// entry point for all state changes. Views call `send(_:)` to
/// trigger the reducer → middleware → effect cycle.
///
/// ```swift
/// @Observable
/// final class AppStore: SwiduxDispatcher {
///     func send(_ action: AppAction) {
///         // reducer + middleware + effect
///     }
/// }
/// ```
public protocol SwiduxDispatcher<Action> {
    associatedtype Action
    func send(_ action: Action)
}

extension SwiduxDispatcher {
    /// Runs an effect on the cooperative thread pool, off the MainActor.
    ///
    /// Effects are `@Sendable ... async -> Void` — designed for background work
    /// (network calls, pixel analysis, etc.). This method uses `@concurrent` so
    /// downstream apps never need `Task.detached` in their code. The `send`
    /// closure hops back to `@MainActor` for each dispatched action.
    ///
    /// ```swift
    /// // In AppStore.send():
    /// if let effect {
    ///     let send: Send<AppAction> = { [weak self] action in
    ///         self?.send(action)
    ///     }
    ///     runEffect(effect, send: send)
    /// }
    /// ```
    public nonisolated func runEffect(
        _ effect: @escaping Effect<Action>,
        send: @escaping Send<Action>
    ) {
        Task { @concurrent in
            await effect(send)
        }
    }
}
