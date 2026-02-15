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
