//
//  SwiduxDispatcher.swift
//  Swidux
//
//  Protocol defining the store dispatch contract.
//

import Foundation

/// A type that can dispatch actions into the Swidux data flow.
///
/// Conforming types (``Store``, which an `AppStore` usually aliases) provide the single
/// entry point for all state changes. Views call `send(_:)` to
/// trigger the plugin → reducer → effect cycle.
///
/// ```swift
/// @Observable
/// final class AppStore: SwiduxDispatcher {
///     func send(_ action: AppAction) {
///         // plugins + reducer + effects
///     }
/// }
/// ```
public protocol SwiduxDispatcher<Action> {
    associatedtype Action
    func send(_ action: Action)
}
