//
//  PluginHost.swift
//  Swidux
//
//  Manages registered plugins and drives their lifecycle.
//

/// Ordered registry of plugins that drives the dispatch lifecycle.
///
/// `PluginHost` is owned by the app's store and called from `send()`.
/// Registration order determines execution order.
///
/// ```swift
/// let plugins = PluginHost<AppState, AppAction>()
/// plugins.register(UndoPlugin(...))
/// plugins.register(PersistencePlugin(...))
/// plugins.register(KillswitchPlugin(...))
///
/// // In send():
/// plugins.willReduce(state: state, action: action)
/// let appEffect = reducer.reduce(...)
/// let pluginEffects = plugins.reduce(state: &state, action: action)
/// plugins.afterReduce(state: &state, action: action)
/// ```
@MainActor
public final class PluginHost<State, Action> {
    /// Registered plugins in execution order.
    public private(set) var plugins: [any SwiduxPlugin<State, Action>] = []

    /// Creates an empty plugin host.
    public init() {}

    /// Appends a plugin. Registration order determines execution order.
    public func register(_ plugin: some SwiduxPlugin<State, Action>) {
        plugins.append(plugin)
    }

    /// Calls `willReduce` on every plugin in registration order.
    public func willReduce(state: State, action: Action) {
        for plugin in plugins {
            plugin.willReduce(state: state, action: action)
        }
    }

    /// Calls `reduce` on every plugin, collecting non-nil effects.
    public func reduce(state: inout State, action: Action) -> [Effect<Action>] {
        plugins.compactMap { $0.reduce(state: &state, action: action) }
    }

    /// Calls `afterReduce` on every plugin in registration order.
    public func afterReduce(state: inout State, action: Action) {
        for plugin in plugins {
            plugin.afterReduce(state: &state, action: action)
        }
    }

    /// Calls `flush` on every plugin in registration order.
    public func flush() async {
        for plugin in plugins {
            await plugin.flush()
        }
    }
}
