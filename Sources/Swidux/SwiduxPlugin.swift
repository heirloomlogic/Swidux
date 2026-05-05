//
//  SwiduxPlugin.swift
//  Swidux
//
//  Unified extension point for the dispatch cycle.
//

/// A plugin that participates in the Swidux dispatch cycle.
///
/// Plugins extend the store's `send()` method with lifecycle hooks and
/// optional action handling. All methods have default no-op implementations;
/// each plugin overrides only what it needs.
///
/// ## Lifecycle
///
/// ```
/// plugins.willReduce(state:action:)   // undo snapshots here
/// appReducer.reduce(state:action:...) // core business logic
/// plugins.reduce(state:action:)       // plugin action handling
/// plugins.afterReduce(state:action:)  // persistence drains here
/// ```
///
/// ## Built-in Plugins
///
/// - ``PersistencePlugin``: Debounced persistence via `afterReduce` + `flush`.
/// - ``UndoPlugin``: Snapshot-based undo/redo via `willReduce`.
///
/// ## Creating a Plugin
///
/// ```swift
/// struct AnalyticsPlugin<State, Action>: SwiduxPlugin {
///     func afterReduce(state: inout State, action: Action) {
///         // log every dispatched action
///     }
/// }
/// ```
@MainActor
public protocol SwiduxPlugin<State, Action> {
    associatedtype State
    associatedtype Action

    /// Called before the app reducer runs.
    func willReduce(state: State, action: Action)

    /// Handle an action after the app reducer. Return an effect or `nil`.
    func reduce(state: inout State, action: Action) -> Effect<Action>?

    /// Called after all reducing is done.
    func afterReduce(state: inout State, action: Action)

    /// Shutdown hook for flushing pending async work.
    func flush() async
}

extension SwiduxPlugin {
    /// No-op default implementation.
    public func willReduce(state: State, action: Action) {}
    /// No-op default implementation; returns `nil`.
    public func reduce(state: inout State, action: Action) -> Effect<Action>? { nil }
    /// No-op default implementation.
    public func afterReduce(state: inout State, action: Action) {}
    /// No-op default implementation.
    public func flush() async {}
}
